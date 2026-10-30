defmodule PostHog.FeatureFlags.Evaluations do
  @moduledoc """
  Snapshot of feature flag evaluations for a single `distinct_id`.

  An `Evaluations` struct represents one point-in-time evaluation assembled
  locally and, when needed, from at most one `/flags` call. It is built by
  `PostHog.FeatureFlags.evaluate_flags/2` and lets you branch on multiple flags
  and enrich captured events from the same frozen result set.

  Each snapshot tracks which flags were accessed via `enabled?/2` and
  `get_flag/2` in an `:atomics` array that is garbage-collected together with
  the snapshot. No process is started and no manual cleanup is required, and a
  snapshot can be shared with other processes.

  ## Querying

  Use `enabled?/2`, `get_flag/2`, and `get_flag_payload/2` to read individual
  flags. `enabled?/2` and `get_flag/2` record access and fire a
  `$feature_flag_called` event with full metadata (id, version, reason,
  request_id) on each call; `get_flag_payload/2` does neither.

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
  `enabled?/2` or `get_flag/2`. Use `only/2` to narrow by an explicit key list.
  Both return a fresh snapshot with its own access tracker — calls on the
  filtered view do not back-propagate to the parent.

      narrowed = PostHog.FeatureFlags.Evaluations.only_accessed(snapshot)
      PostHog.FeatureFlags.set_in_context(narrowed)
  """

  alias PostHog.FeatureFlags.Result

  @typedoc """
  Snapshot of evaluated flags for a single `distinct_id`.

  - `:supervisor_name` - PostHog instance the snapshot was produced from; used
    when `enabled?/2` and `get_flag/2` fire `$feature_flag_called` events.
  - `:distinct_id` - resolved distinct ID the local and/or remote evaluation
    was performed for. `""` for the empty fallback returned when no
    `distinct_id` could be resolved; events are short-circuited in that case.
  - `:flags` - map of flag key to `t:PostHog.FeatureFlags.Result.t/0`.
  - `:groups` - normalized group type/key context used for evaluation and
    `$feature_flag_called` deduplication.
  - `:request_id` - request ID returned when remote fallback was used.
  - `:evaluated_at` - server-side evaluation timestamp when remote fallback was used.
  - `:errors_while_computing` - whether the response signaled
    `errorsWhileComputingFlags`. When `true`, every event fired from this
    snapshot includes `errors_while_computing_flags` in its
    `$feature_flag_error` property.
  - `:accessed` - internal. Its contents may change in any release without
    notice. Don't read or match on it; use `accessed/1`.
  - `:accessed_pid` - internal and deprecated. Always `nil`. It held the pid of
    an internal Agent that tracked accessed keys and was never meant to be
    used directly. Snapshots no longer start a process, so there is nothing to
    stop or clean up, and the process leak this Agent caused no longer
    happens. Kept only so existing code that reads or matches the field still
    compiles. Don't use it; it will be removed in the next major version.
  """
  @type t :: %__MODULE__{
          supervisor_name: PostHog.supervisor_name(),
          distinct_id: PostHog.distinct_id(),
          flags: %{String.t() => Result.t()},
          groups: %{String.t() => String.t()},
          request_id: String.t() | nil,
          evaluated_at: integer() | nil,
          errors_while_computing: boolean(),
          accessed: accessed(),
          accessed_pid: nil
        }

  @typedoc false
  @opaque accessed :: {%{String.t() => pos_integer()}, :atomics.atomics_ref() | nil}

  @enforce_keys [:supervisor_name, :distinct_id, :flags, :accessed]
  defstruct [
    :supervisor_name,
    :distinct_id,
    :flags,
    :accessed,
    # Deprecated and always nil. Kept for compatibility with code written for
    # the old Agent-based tracker.
    :accessed_pid,
    :request_id,
    :evaluated_at,
    groups: %{},
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
      groups: normalize_groups(Map.get(body, :groups, Map.get(body, "groups", %{}))),
      accessed: new_accessed(flags)
    }
  end

  @doc false
  @spec from_results(
          PostHog.supervisor_name(),
          PostHog.distinct_id(),
          %{String.t() => Result.t()},
          map()
        ) :: t()
  def from_results(supervisor_name, distinct_id, results, metadata)
      when is_map(results) and is_map(metadata) do
    %__MODULE__{
      supervisor_name: supervisor_name,
      distinct_id: distinct_id,
      flags: results,
      request_id: Map.get(metadata, :request_id, Map.get(metadata, "requestId")),
      evaluated_at: Map.get(metadata, :evaluated_at, Map.get(metadata, "evaluatedAt")),
      errors_while_computing:
        Map.get(metadata, :errors_while_computing, Map.get(metadata, "errorsWhileComputingFlags")) ==
          true,
      groups: normalize_groups(Map.get(metadata, :groups, Map.get(metadata, "groups", %{}))),
      accessed: new_accessed(results)
    }
  end

  @doc false
  @spec empty(PostHog.supervisor_name()) :: t()
  def empty(supervisor_name) do
    %__MODULE__{
      supervisor_name: supervisor_name,
      distinct_id: "",
      flags: %{},
      accessed: new_accessed(%{})
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
  flags without a payload.

  Does **not** record access for `only_accessed/1` or fire a
  `$feature_flag_called` event.
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
  Returns the sorted list of keys present in this snapshot that were accessed
  via `enabled?/2` or `get_flag/2`.

  Keys that were accessed but are absent from the snapshot are not included.
  """
  @spec accessed(t()) :: [String.t()]
  def accessed(%__MODULE__{accessed: {_indexes, nil}}), do: []

  def accessed(%__MODULE__{accessed: {indexes, ref}}) do
    indexes
    |> Enum.filter(fn {_key, index} -> :atomics.get(ref, index) == 1 end)
    |> Enum.map(fn {key, _index} -> key end)
    |> Enum.sort()
  end

  @doc """
  Returns a copy of the snapshot scoped to the flags accessed so far via
  `enabled?/2` or `get_flag/2`.

  Returns an empty snapshot when nothing has been accessed yet — including
  no flags would be more surprising than helpful, since the caller asked for
  "only what I touched."

  The returned snapshot has its own access tracker. Calls on it do not
  back-propagate to the parent.
  """
  @spec only_accessed(t()) :: t()
  def only_accessed(%__MODULE__{flags: flags} = snapshot) do
    clone_with(snapshot, Map.take(flags, accessed(snapshot)))
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
  @spec event_properties(t()) :: PostHog.properties()
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

  # :atomics are garbage-collected with the snapshot, unlike a process-based
  # tracker, which would live until its owner exits.
  defp new_accessed(flags) when map_size(flags) == 0, do: {%{}, nil}

  defp new_accessed(flags) do
    indexes = flags |> Map.keys() |> Enum.with_index(1) |> Map.new()
    {indexes, :atomics.new(map_size(indexes), signed: false)}
  end

  defp record_access(%__MODULE__{accessed: {indexes, ref}}, key) do
    case Map.fetch(indexes, key) do
      {:ok, index} -> :atomics.put(ref, index, 1)
      :error -> :ok
    end
  end

  defp clone_with(%__MODULE__{} = snapshot, flags) do
    %{snapshot | flags: flags, accessed: new_accessed(flags)}
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
         %__MODULE__{
           supervisor_name: name,
           distinct_id: distinct_id,
           groups: groups,
           errors_while_computing: snapshot_error?
         },
         %Result{} = result,
         extra_errors
       ) do
    result = %{
      result
      | errors_while_computing: result.errors_while_computing or snapshot_error?
    }

    PostHog.FeatureFlags.log_feature_flag_usage(name, distinct_id, result, extra_errors, groups)
  end

  defp normalize_groups(groups) when is_map(groups) do
    Map.new(groups, fn {group_type, group_key} ->
      {to_string(group_type), to_string(group_key)}
    end)
  end

  defp normalize_groups(_groups), do: %{}
end
