defmodule PostHog.FeatureFlags.Evaluations do
  @moduledoc """
  Snapshot of feature flag evaluations for a single `distinct_id`.

  An `Evaluations` struct represents the result of a single `/flags` call. It is
  built by `PostHog.FeatureFlags.evaluate_flags/2` and lets you branch on
  multiple flags and enrich captured events from the same fetch — without
  paying the cost of one round-trip per flag.

  Each snapshot owns a small `Agent` linked to the calling process that tracks
  which flags were accessed via `enabled?/2`, `get_flag/2`, and
  `get_flag_payload/2`. The Agent exits with the calling process — no manual
  cleanup is required.

  ## Querying

  Use `enabled?/2`, `get_flag/2`, and `get_flag_payload/2` to read individual
  flags. `enabled?/2` and `get_flag/2` fire a `$feature_flag_called` event
  with full metadata (id, version, reason, request_id) on each call;
  `get_flag_payload/2` records the access without firing an event.

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

  Use `only_accessed/1` to narrow a snapshot to flags accessed so far via
  `enabled?/2`, `get_flag/2`, or `get_flag_payload/2`. Use `only/2` to narrow
  by an explicit key list. Both return a fresh snapshot with its own access
  tracker — calls on the filtered view do not back-propagate to the parent.

      narrowed = PostHog.FeatureFlags.Evaluations.only_accessed(snapshot)
      PostHog.FeatureFlags.set_in_context(narrowed)
  """

  alias PostHog.FeatureFlags.Result

  @typedoc """
  Snapshot of evaluated flags for a single `distinct_id`.

  - `:supervisor_name` - PostHog instance the snapshot was produced from; used
    when `enabled?/2` and `get_flag/2` fire `$feature_flag_called` events.
  - `:distinct_id` - resolved distinct ID the `/flags` request was made for.
    `""` for the empty fallback returned when no `distinct_id` could be
    resolved; events are short-circuited in that case.
  - `:flags` - map of flag key to `t:PostHog.FeatureFlags.Result.t/0`.
  - `:request_id` - request ID returned by `/flags`.
  - `:evaluated_at` - server-side evaluation timestamp.
  - `:errors_while_computing` - whether the response signaled
    `errorsWhileComputingFlags`. When `true`, every event fired from this
    snapshot includes `errors_while_computing_flags` in its
    `$feature_flag_error` property.
  - `:accessed_pid` - pid of the Agent tracking accessed keys.
  """
  @type t :: %__MODULE__{
          supervisor_name: PostHog.supervisor_name(),
          distinct_id: PostHog.distinct_id(),
          flags: %{String.t() => Result.t()},
          request_id: String.t() | nil,
          evaluated_at: integer() | nil,
          errors_while_computing: boolean(),
          accessed_pid: pid()
        }

  @enforce_keys [:supervisor_name, :distinct_id, :flags, :accessed_pid]
  defstruct [
    :supervisor_name,
    :distinct_id,
    :flags,
    :accessed_pid,
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
      errors_while_computing: Map.get(body, "errorsWhileComputingFlags") == true,
      accessed_pid: start_accessed_agent()
    }
  end

  @doc false
  @spec empty(PostHog.supervisor_name()) :: t()
  def empty(supervisor_name) do
    %__MODULE__{
      supervisor_name: supervisor_name,
      distinct_id: "",
      flags: %{},
      accessed_pid: start_accessed_agent()
    }
  end

  @doc """
  Returns whether the named flag is enabled in this snapshot.

  Returns `false` for unknown flags. Records the access. Fires a
  `$feature_flag_called` event with full metadata when the flag is present,
  or with `$feature_flag_error: "flag_missing"` and
  `$feature_flag_response: nil` when it is not.
  """
  @spec enabled?(t(), String.t()) :: boolean()
  def enabled?(%__MODULE__{} = snapshot, key) when is_binary(key) do
    record_access(snapshot, key)

    case fetch_and_log(snapshot, key) do
      {:ok, %Result{enabled: enabled}} -> enabled
      :error -> false
    end
  end

  @doc """
  Returns the variant string, the enabled boolean, or `nil` for unknown flags.

  Records the access. Fires a `$feature_flag_called` event with full metadata
  when the flag is present, or with `$feature_flag_error: "flag_missing"` and
  `$feature_flag_response: nil` when it is not.
  """
  @spec get_flag(t(), String.t()) :: String.t() | boolean() | nil
  def get_flag(%__MODULE__{} = snapshot, key) when is_binary(key) do
    record_access(snapshot, key)

    case fetch_and_log(snapshot, key) do
      {:ok, %Result{} = result} -> Result.value(result)
      :error -> nil
    end
  end

  @doc """
  Returns the configured payload for the flag, or `nil` for unknown flags or
  flags without a payload. Records the access.

  Does **not** fire a `$feature_flag_called` event.
  """
  @spec get_flag_payload(t(), String.t()) :: any() | nil
  def get_flag_payload(%__MODULE__{flags: flags} = snapshot, key) when is_binary(key) do
    record_access(snapshot, key)

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
  Returns the sorted list of keys accessed via `enabled?/2`, `get_flag/2`, or
  `get_flag_payload/2` on this snapshot.

  Includes keys that were accessed but absent from the snapshot.
  """
  @spec accessed(t()) :: [String.t()]
  def accessed(%__MODULE__{accessed_pid: pid}) do
    pid |> Agent.get(& &1) |> MapSet.to_list() |> Enum.sort()
  end

  @doc """
  Returns a copy of the snapshot scoped to the flags accessed so far via
  `enabled?/2`, `get_flag/2`, or `get_flag_payload/2`.

  Returns an empty snapshot when nothing has been accessed yet — including
  no flags would be more surprising than helpful, since the caller asked for
  "only what I touched."

  The returned snapshot has its own access tracker. Calls on it do not
  back-propagate to the parent.
  """
  @spec only_accessed(t()) :: t()
  def only_accessed(%__MODULE__{flags: flags} = snapshot) do
    accessed_set = MapSet.new(accessed(snapshot))
    keep = flags |> Map.keys() |> Enum.filter(&MapSet.member?(accessed_set, &1))
    clone_with(snapshot, Map.take(flags, keep))
  end

  @doc """
  Returns a copy of the snapshot scoped to the given keys. Unknown keys are
  silently dropped.

  The returned snapshot has its own access tracker. Calls on it do not
  back-propagate to the parent.
  """
  @spec only(t(), [String.t()]) :: t()
  def only(%__MODULE__{flags: flags} = snapshot, keys) when is_list(keys) do
    clone_with(snapshot, Map.take(flags, keys))
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

  defp start_accessed_agent do
    {:ok, pid} = Agent.start_link(fn -> MapSet.new() end)
    pid
  end

  defp record_access(%__MODULE__{accessed_pid: pid}, key) do
    Agent.update(pid, &MapSet.put(&1, key))
  end

  defp clone_with(%__MODULE__{} = snapshot, flags) do
    %{snapshot | flags: flags, accessed_pid: start_accessed_agent()}
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
