defmodule PostHog.FeatureFlags.Evaluations do
  @moduledoc """
  Snapshot of feature flag evaluations for a single `distinct_id`.

  An `Evaluations` struct represents the result of a single `/flags` call. It is
  built by `PostHog.FeatureFlags.evaluate_flags/2` and lets you branch on
  multiple flags and enrich captured events from the same fetch — without
  paying the cost of one round-trip per flag.

  The struct itself is a plain immutable map of flag key to
  `PostHog.FeatureFlags.Result`. Functions in this module are pure: they query
  or filter a snapshot but never mutate it.

  ## Querying

  Use `enabled?/2`, `get_flag/2`, and `get_flag_payload/2` to read individual
  flags. `enabled?/2` and `get_flag/2` fire a `$feature_flag_called` event
  with full metadata (id, version, reason, request_id) on each call;
  `get_flag_payload/2` does not fire an event.

      {:ok, snapshot} = PostHog.FeatureFlags.evaluate_flags("user-123")

      if PostHog.FeatureFlags.Evaluations.enabled?(snapshot, "new-dashboard") do
        render_new_dashboard()
      end

  ## Enriching captures

  Call `PostHog.FeatureFlags.set_in_context/2` to copy the snapshot's
  `$feature/<key>` and `$active_feature_flags` properties into the per-process
  context. Any subsequent `PostHog.capture/3` automatically picks them up — no
  additional `/flags` request, and the values match what you branched on.

      PostHog.FeatureFlags.set_in_context(snapshot)
      PostHog.capture("page_viewed", %{distinct_id: "user-123"})

  Or merge `event_properties/1` directly into a capture's properties for an
  explicit, one-off attach without touching context.

  ## Filtering

  Use `only/2` to narrow a snapshot to a specific list of flag keys before
  calling `set_in_context/2` or `event_properties/1`. Unknown keys are dropped.

      narrowed = PostHog.FeatureFlags.Evaluations.only(snapshot, ["new-dashboard"])
      PostHog.FeatureFlags.set_in_context(narrowed)
  """

  alias PostHog.FeatureFlags.Result

  @typedoc """
  Snapshot of evaluated flags for a single `distinct_id`.

  - `:supervisor_name` - PostHog instance the snapshot was produced from; used
    when `enabled?/2` and `get_flag/2` fire `$feature_flag_called` events.
  - `:distinct_id` - resolved distinct ID the `/flags` request was made for.
  - `:flags` - map of flag key to `t:PostHog.FeatureFlags.Result.t/0`.
  - `:request_id` - request ID returned by `/flags`.
  - `:evaluated_at` - server-side evaluation timestamp.
  - `:errors_while_computing` - whether the response signaled
    `errorsWhileComputingFlags`. When `true`, every event fired from this
    snapshot includes `errors_while_computing_flags` in its
    `$feature_flag_error` property.
  """
  @type t :: %__MODULE__{
          supervisor_name: PostHog.supervisor_name(),
          distinct_id: PostHog.distinct_id(),
          flags: %{String.t() => Result.t()},
          request_id: String.t() | nil,
          evaluated_at: integer() | nil,
          errors_while_computing: boolean()
        }

  @enforce_keys [:supervisor_name, :distinct_id, :flags]
  defstruct [
    :supervisor_name,
    :distinct_id,
    :flags,
    :request_id,
    :evaluated_at,
    errors_while_computing: false
  ]

  @doc false
  @spec new(PostHog.supervisor_name(), PostHog.distinct_id(), map()) :: t()
  def new(supervisor_name, distinct_id, %{"flags" => flags_data} = body)
      when is_map(flags_data) do
    flags =
      Map.new(flags_data, fn {key, flag_data} ->
        {key, PostHog.FeatureFlags.build_result(key, flag_data, body)}
      end)

    %__MODULE__{
      supervisor_name: supervisor_name,
      distinct_id: distinct_id,
      flags: flags,
      request_id: Map.get(body, "requestId"),
      evaluated_at: Map.get(body, "evaluatedAt"),
      errors_while_computing: Map.get(body, "errorsWhileComputingFlags") == true
    }
  end

  @doc """
  Returns whether the named flag is enabled in this snapshot.

  Returns `false` for unknown flags. Fires a `$feature_flag_called` event with
  full metadata when the flag is present, or with
  `$feature_flag_error: "flag_missing"` when it is not.
  """
  @spec enabled?(t(), String.t()) :: boolean()
  def enabled?(%__MODULE__{} = snapshot, key) when is_binary(key) do
    case fetch_and_log(snapshot, key) do
      {:ok, %Result{enabled: enabled}} -> enabled
      :error -> false
    end
  end

  @doc """
  Returns the variant string, the enabled boolean, or `nil` for unknown flags.

  Fires a `$feature_flag_called` event with full metadata when the flag is
  present, or with `$feature_flag_error: "flag_missing"` when it is not.
  """
  @spec get_flag(t(), String.t()) :: String.t() | boolean() | nil
  def get_flag(%__MODULE__{} = snapshot, key) when is_binary(key) do
    case fetch_and_log(snapshot, key) do
      {:ok, %Result{} = result} -> Result.value(result)
      :error -> nil
    end
  end

  @doc """
  Returns the configured payload for the flag, or `nil` for unknown flags or
  flags without a payload.

  Does **not** fire a `$feature_flag_called` event.
  """
  @spec get_flag_payload(t(), String.t()) :: any() | nil
  def get_flag_payload(%__MODULE__{flags: flags}, key) when is_binary(key) do
    case Map.fetch(flags, key) do
      {:ok, %Result{payload: payload}} -> payload
      :error -> nil
    end
  end

  @doc """
  Returns the sorted list of flag keys present in the snapshot.
  """
  @spec keys(t()) :: [String.t()]
  def keys(%__MODULE__{flags: flags}), do: flags |> Map.keys() |> Enum.sort()

  @doc """
  Returns a copy of the snapshot scoped to the given keys. Unknown keys are
  silently dropped — the resulting snapshot contains only the intersection of
  the requested keys with the snapshot's keys.
  """
  @spec only(t(), [String.t()]) :: t()
  def only(%__MODULE__{flags: flags} = snapshot, keys) when is_list(keys) do
    %{snapshot | flags: Map.take(flags, keys)}
  end

  @doc """
  Returns the `$feature/<key>` and `$active_feature_flags` properties for this
  snapshot, suitable for merging into a captured event's properties.

  - `$feature/<key>` is set to the variant string when present, or to the
    enabled boolean otherwise. Disabled flags are included with `false`.
  - `$active_feature_flags` is the sorted list of keys whose flag is enabled.

  ## Examples

      properties = PostHog.FeatureFlags.Evaluations.event_properties(snapshot)
      PostHog.capture("page_viewed", Map.merge(%{distinct_id: "u1"}, properties))
  """
  @spec event_properties(t()) :: %{String.t() => any()}
  def event_properties(%__MODULE__{flags: flags}) do
    {properties, active} =
      Enum.reduce(flags, {%{}, []}, fn {key, %Result{} = result}, {props, active} ->
        value = Result.value(result)
        props = Map.put(props, "$feature/#{key}", value)
        active = if result.enabled, do: [key | active], else: active
        {props, active}
      end)

    case active do
      [] -> properties
      keys -> Map.put(properties, :"$active_feature_flags", Enum.sort(keys))
    end
  end

  defp fetch_and_log(%__MODULE__{flags: flags} = snapshot, key) do
    case Map.fetch(flags, key) do
      {:ok, %Result{} = result} ->
        log(snapshot, result, [])
        {:ok, result}

      :error ->
        log(snapshot, missing_result(snapshot, key), ["flag_missing"])
        :error
    end
  end

  defp missing_result(%__MODULE__{errors_while_computing: ewc}, key) do
    %Result{key: key, enabled: false, errors_while_computing: ewc}
  end

  defp log(%__MODULE__{distinct_id: ""}, _result, _extra_errors), do: :ok

  defp log(
         %__MODULE__{supervisor_name: name, distinct_id: distinct_id},
         %Result{} = result,
         extra_errors
       ) do
    PostHog.FeatureFlags.log_feature_flag_usage(name, distinct_id, result, extra_errors)
  end
end
