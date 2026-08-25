defmodule PostHog.FeatureFlags do
  @moduledoc """
  Convenience functions to work with Feature Flags API
  """

  @doc """
  Make request to [`/flags`](https://posthog.com/docs/api/flags) API.

  This function is a thin wrapper over a client call and is useful as a building
  block to build your own `check/3`. For example, this is a preferred
  way to access remote config payload.

  ## Examples

  Make request to `/flags` API:

      PostHog.FeatureFlags.flags(%{distinct_id: "user123"})

  Make request to `/flags` API with additional body params:

      PostHog.FeatureFlags.flags(%{distinct_id: "my_distinct_id", groups: %{group_type: "group_id"}})

  Make request to `/flags` API through a named PostHog instance:

      PostHog.FeatureFlags.flags(MyPostHog, %{distinct_id: "user123"})
  """
  @spec flags(PostHog.supervisor_name(), map()) ::
          PostHog.API.Client.response() | {:error, PostHog.Error.t()}
  def flags(name \\ PostHog, body) do
    config = PostHog.config(name)

    if Map.get(config, :enabled, true) do
      request_flags(config.api_client, translate_disable_geoip(body))
    else
      empty_flags_response()
    end
  end

  defp request_flags(api_client, body) do
    case PostHog.API.flags(api_client, body) do
      {:ok, %{status: 200, body: %{"flags" => _}}} = resp ->
        resp

      {:ok, %{status: 200, body: body}} ->
        {:error,
         %PostHog.UnexpectedResponseError{
           response: body,
           message: "Expected response body to have \"flags\" key"
         }}

      {:ok, resp} ->
        {:error, %PostHog.UnexpectedResponseError{response: resp, message: "Unexpected response"}}

      {:error, _} = error ->
        error
    end
  end

  defp empty_flags_response, do: {:ok, %{status: 200, body: %{"flags" => %{}}}}

  @doc false
  def flags_for(distinct_id_or_body) when not is_atom(distinct_id_or_body),
    do: flags_for(PostHog, distinct_id_or_body)

  @doc """
  Get all feature flags.

  Accepts an optional `distinct_id` or a map with request body. If neither is
  passed, attempts to read `distinct_id` from the context.

  ## Examples

  Get all feature flags:

      PostHog.FeatureFlags.flags_for("user123")

  Get all feature flags with full request body:

      PostHog.FeatureFlags.flags_for(%{distinct_id: "user123", groups: %{group_type: "group_id"}})

  Get all feature flags for `distinct_id` from the context:

      PostHog.set_context(%{distinct_id: "user123"})
      PostHog.FeatureFlags.flags_for()

  Get all feature flags through a named PostHog instance:

      PostHog.FeatureFlags.flags_for(MyPostHog, "foo")
  """
  @spec flags_for(PostHog.supervisor_name(), PostHog.distinct_id() | map() | nil) ::
          {:ok, map()} | {:error, Exception.t()}
  def flags_for(name \\ PostHog, distinct_id_or_body \\ nil) do
    with {:ok, body} <- body_for_flags(name, distinct_id_or_body),
         {:ok, %{body: %{"flags" => flags}}} <- flags(name, body) do
      {:ok, flags}
    end
  end

  @doc false
  def evaluate_flags(nil), do: evaluate_flags(PostHog, nil)

  def evaluate_flags(distinct_id_or_body) when not is_atom(distinct_id_or_body),
    do: evaluate_flags(PostHog, distinct_id_or_body)

  @doc """
  Evaluates feature flags for a `distinct_id` and returns a snapshot.

  Returns `{:ok, %PostHog.FeatureFlags.Evaluations{}}` on success. Definitions
  are evaluated locally first when privileged local evaluation is configured;
  unresolved flags are filled by at most one `/flags` call. If that fallback
  fails after some flags resolved locally, the successful local subset is
  returned as a partial snapshot. If nothing resolved, the remote error is
  returned to preserve the existing `{:error, reason}` contract. The snapshot
  lets you branch on multiple flags and enrich
  captured events — see
  `PostHog.FeatureFlags.Evaluations` for the full snapshot API and
  `set_in_context/2` for the recommended capture-enrichment flow.

  Accepts an optional `distinct_id` or a request body map. If neither is
  passed, attempts to read `distinct_id` from the context.

  ## Body options

  When passing a map, the following keys are forwarded to the `/flags` request
  body unchanged:

  - `:distinct_id` (required, unless found in context)
  - `:groups`
  - `:person_properties`
  - `:group_properties`
  - `:device_id` - alternate bucketing identifier for device-bucketed flags

  The public `:disable_geoip` option is sent under the `/flags` wire key
  `geoip_disable`.

  Plus these snapshot-specific options:

  - `:only_evaluate_locally` - when true, never calls `/flags`; unresolved
    flags are omitted from the snapshot.

  - `:flag_keys` - list of flag keys. A non-empty list is forwarded to the
    request as `flag_keys_to_evaluate` so the server returns only those flags.
    An empty list returns an empty snapshot without making a request. An
    omitted or `nil` value evaluates all flags through the normal request path.
    This scopes the network response, distinct from
    `PostHog.FeatureFlags.Evaluations.only/2` which filters an already-fetched
    snapshot in memory. Clean remote omissions for explicitly requested keys
    are retained in a bounded per-instance set until definitions refresh, so
    repeated and concurrent missing-key probes avoid duplicate requests.

  ## Examples

  Evaluate flags for a `distinct_id`:

      {:ok, snapshot} = PostHog.FeatureFlags.evaluate_flags("user123")
      PostHog.FeatureFlags.Evaluations.enabled?(snapshot, "new-dashboard")

  Evaluate a scoped set of flags with person properties:

      PostHog.FeatureFlags.evaluate_flags(%{
        distinct_id: "user123",
        person_properties: %{plan: "enterprise"},
        flag_keys: ["new-dashboard", "beta-checkout"]
      })

  Evaluate through a named PostHog instance:

      PostHog.FeatureFlags.evaluate_flags(MyPostHog, "user123")
  """
  @spec evaluate_flags(PostHog.supervisor_name(), PostHog.distinct_id() | map() | nil) ::
          {:ok, __MODULE__.Evaluations.t()} | {:error, Exception.t()}
  def evaluate_flags(name \\ PostHog, distinct_id_or_body \\ nil) do
    case body_for_flags(name, distinct_id_or_body) do
      {:ok, %{distinct_id: distinct_id, flag_keys: []} = body} ->
        metadata = %{groups: evaluation_groups(body)}
        {:ok, __MODULE__.Evaluations.from_results(name, distinct_id, %{}, metadata)}

      {:ok, %{distinct_id: distinct_id} = body} ->
        evaluate_snapshot(name, distinct_id, body)

      {:error, _} ->
        # Standardize on returning an empty snapshot when distinct_id can't be
        # resolved — matches the cross-SDK behavior. The empty distinct_id
        # short-circuits event firing in `enabled?/2` and `get_flag/2`, so no
        # events leak with an empty distinct_id.
        {:ok, __MODULE__.Evaluations.empty(name)}
    end
  end

  defp evaluate_snapshot(name, distinct_id, body) do
    only_local? = Map.get(body, :only_evaluate_locally, false) == true
    requested_keys = Map.get(body, :flag_keys)
    loader_state = local_evaluation_state(name, requested_keys || [])

    case loader_state.definitions do
      nil ->
        if only_local? do
          snapshot_from_results(name, distinct_id, %{}, body)
        else
          remote_snapshot(name, distinct_id, body, %{}, requested_keys, nil, [])
        end

      _definitions ->
        evaluate_loaded_snapshot(
          name,
          distinct_id,
          body,
          requested_keys,
          loader_state,
          true,
          nil
        )
    end
  end

  defp evaluate_loaded_snapshot(
         name,
         distinct_id,
         body,
         requested_keys,
         loader_state,
         coordinate_missing?,
         owned_probe_keys
       ) do
    definitions = loader_state.definitions
    only_local? = Map.get(body, :only_evaluate_locally, false) == true

    if is_nil(requested_keys) and map_size(definitions.flags_by_key) == 0 and not only_local? do
      remote_loaded_snapshot(
        name,
        distinct_id,
        body,
        requested_keys,
        loader_state,
        %{results: %{}},
        owned_probe_keys
      )
    else
      evaluate_nonempty_loaded_snapshot(
        name,
        distinct_id,
        body,
        requested_keys,
        loader_state,
        coordinate_missing?,
        owned_probe_keys
      )
    end
  end

  defp evaluate_nonempty_loaded_snapshot(
         name,
         distinct_id,
         body,
         requested_keys,
         loader_state,
         coordinate_missing?,
         owned_probe_keys
       ) do
    definitions = loader_state.definitions
    keys = requested_keys || Map.keys(definitions.flags_by_key)
    local = __MODULE__.LocalEvaluator.evaluate(definitions, body, keys)
    known_missing = if is_list(requested_keys), do: loader_state.known_missing, else: MapSet.new()
    unresolved = MapSet.difference(local.unresolved, known_missing)
    only_local? = Map.get(body, :only_evaluate_locally, false) == true

    cond do
      only_local? or MapSet.size(unresolved) == 0 ->
        snapshot_from_results(name, distinct_id, local.results, body)

      coordinate_missing? and is_list(requested_keys) ->
        coordinate_missing_probe(
          name,
          distinct_id,
          body,
          requested_keys,
          loader_state,
          local,
          unresolved
        )

      true ->
        remote_loaded_snapshot(
          name,
          distinct_id,
          body,
          requested_keys,
          loader_state,
          local,
          owned_probe_keys
        )
    end
  end

  defp coordinate_missing_probe(
         name,
         distinct_id,
         body,
         requested_keys,
         loader_state,
         local,
         unresolved
       ) do
    absent = absent_definition_keys(requested_keys, loader_state.definitions)
    probe_keys = absent |> MapSet.intersection(unresolved) |> MapSet.to_list()

    if probe_keys == [] do
      remote_snapshot(
        name,
        distinct_id,
        body,
        local.results,
        requested_keys,
        loader_state.generation,
        []
      )
    else
      with_missing_probe_locks(name, probe_keys, fn ->
        evaluate_after_missing_probe_lock(name, distinct_id, body, requested_keys, probe_keys)
      end)
    end
  end

  defp evaluate_after_missing_probe_lock(name, distinct_id, body, requested_keys, probe_keys) do
    fresh_state = local_evaluation_state(name, requested_keys)

    if is_nil(fresh_state.definitions) do
      remote_snapshot(name, distinct_id, body, %{}, requested_keys, nil, [])
    else
      evaluate_loaded_snapshot(
        name,
        distinct_id,
        body,
        requested_keys,
        fresh_state,
        false,
        probe_keys
      )
    end
  end

  defp remote_loaded_snapshot(
         name,
         distinct_id,
         body,
         requested_keys,
         loader_state,
         local,
         owned_probe_keys
       ) do
    absent =
      cond do
        is_list(owned_probe_keys) ->
          owned_probe_keys

        is_list(requested_keys) ->
          requested_keys
          |> absent_definition_keys(loader_state.definitions)
          |> MapSet.to_list()

        true ->
          []
      end

    remote_snapshot(
      name,
      distinct_id,
      body,
      local.results,
      requested_keys,
      loader_state.generation,
      absent
    )
  end

  defp absent_definition_keys(requested_keys, definitions) do
    requested_keys
    |> MapSet.new()
    |> MapSet.difference(MapSet.new(Map.keys(definitions.flags_by_key)))
  end

  defp remote_snapshot(
         name,
         distinct_id,
         body,
         local_results,
         requested_keys,
         generation,
         negative_candidates
       ) do
    remote_body =
      body
      |> Map.delete(:only_evaluate_locally)
      |> translate_flag_keys()

    case flags(name, remote_body) do
      {:ok, %{body: %{"flags" => remote_flags} = response_body}} when is_map(remote_flags) ->
        scoped_remote_flags = maybe_scope_remote_results(remote_flags, requested_keys)
        {remote_results, malformed?} = build_remote_results(scoped_remote_flags, response_body)

        update_negative_knowledge(
          name,
          generation,
          negative_candidates,
          Map.keys(scoped_remote_flags),
          clean_remote_response?(response_body) and not malformed?
        )

        merged = Map.merge(remote_results, local_results)

        if malformed? and map_size(merged) == 0 do
          remote_failure_result(
            name,
            distinct_id,
            local_results,
            body,
            invalid_flags_response()
          )
        else
          metadata = Map.put(response_body, :groups, evaluation_groups(body))
          {:ok, __MODULE__.Evaluations.from_results(name, distinct_id, merged, metadata)}
        end

      {:ok, _malformed_response} ->
        remote_failure_result(name, distinct_id, local_results, body, invalid_flags_response())

      {:error, _reason} = error ->
        remote_failure_result(name, distinct_id, local_results, body, error)
    end
  end

  defp remote_failure_result(_name, _distinct_id, local_results, _body, error)
       when map_size(local_results) == 0,
       do: error

  defp remote_failure_result(name, distinct_id, local_results, body, _error),
    do: snapshot_from_results(name, distinct_id, local_results, body)

  defp snapshot_from_results(name, distinct_id, results, body) do
    metadata = %{groups: evaluation_groups(body)}
    {:ok, __MODULE__.Evaluations.from_results(name, distinct_id, results, metadata)}
  end

  defp build_remote_results(flags, response_body) do
    Enum.reduce(flags, {%{}, false}, fn
      {key, flag_data}, {results, malformed?} when is_binary(key) and is_map(flag_data) ->
        {Map.put(results, key, build_result(key, flag_data, response_body)), malformed?}

      _entry, {results, _malformed?} ->
        {results, true}
    end)
  end

  defp invalid_flags_response,
    do: {:error, %RuntimeError{message: "invalid response from PostHog /flags endpoint"}}

  defp evaluation_groups(body) when is_map(body),
    do: Map.get(body, :groups, Map.get(body, "groups", %{})) || %{}

  defp clean_remote_response?(body) do
    Map.get(body, "errorsWhileComputingFlags") != true and
      Map.get(body, "quotaLimited") in [nil, false, []]
  end

  defp update_negative_knowledge(_name, nil, _requested, _returned, _clean?), do: :ok

  defp update_negative_knowledge(name, generation, requested, returned, clean?) do
    __MODULE__.DefinitionLoader.update_negative_knowledge(
      name,
      generation,
      requested,
      returned,
      clean?
    )
  catch
    :exit, _reason -> :ok
  end

  defp maybe_scope_remote_results(results, keys) when is_list(keys), do: Map.take(results, keys)
  defp maybe_scope_remote_results(results, _keys), do: results

  defp local_evaluation_state(name, keys) do
    registry = PostHog.Registry.registry_name(name)

    if Process.whereis(registry) &&
         GenServer.whereis(PostHog.Registry.via(name, __MODULE__.DefinitionLoader)) do
      __MODULE__.DefinitionLoader.evaluation_state(name, keys)
    else
      %{definitions: nil, generation: nil, known_missing: MapSet.new()}
    end
  catch
    :exit, _reason -> %{definitions: nil, generation: nil, known_missing: MapSet.new()}
  end

  defp with_missing_probe_locks(name, keys, callback) do
    keys
    |> Enum.uniq()
    |> Enum.sort()
    |> acquire_missing_probe_locks(name, callback)
  end

  defp acquire_missing_probe_locks([], _name, callback), do: callback.()

  defp acquire_missing_probe_locks([key | rest], name, callback) do
    lock = {{__MODULE__, :missing_probe, name, key}, self()}
    :global.trans(lock, fn -> acquire_missing_probe_locks(rest, name, callback) end)
  end

  @doc """
  Copies a snapshot's `$feature/<key>` and `$active_feature_flags` properties
  into the default per-process PostHog context.

  ## Parameters

  - `snapshot` - `t:PostHog.FeatureFlags.Evaluations.t/0` returned by
    `evaluate_flags/2` or one of the filtering helpers.

  ## Returns

  Returns `:ok`.

  ## Remarks

  Any subsequent `PostHog.capture/3` from this process automatically attaches
  these properties to the captured event — no additional `/flags` request,
  with the values guaranteed to match what the snapshot already evaluated.

  For one-off enrichment without touching context, merge
  `PostHog.FeatureFlags.Evaluations.event_properties/1` into a capture's
  properties directly.

  ## Examples

      {:ok, snapshot} = PostHog.FeatureFlags.evaluate_flags("user123")
      PostHog.FeatureFlags.set_in_context(snapshot)

      # All subsequent captures pick up $feature/* and $active_feature_flags
      PostHog.capture("page_viewed", %{distinct_id: "user123"})
  """
  @spec set_in_context(__MODULE__.Evaluations.t()) :: :ok
  def set_in_context(%__MODULE__.Evaluations{} = snapshot),
    do: set_in_context(PostHog, snapshot)

  @doc """
  Copies a snapshot's `$feature/<key>` and `$active_feature_flags` properties
  into a named PostHog instance's per-process context.

  ## Parameters

  - `name` - supervisor name of the PostHog instance whose context should be
    updated.
  - `snapshot` - `t:PostHog.FeatureFlags.Evaluations.t/0` returned by
    `evaluate_flags/2` or one of the filtering helpers.

  ## Returns

  Returns `:ok`.

  ## Remarks

  This is the named-instance variant of `set_in_context/1`.
  """
  @spec set_in_context(PostHog.supervisor_name(), __MODULE__.Evaluations.t()) :: :ok
  def set_in_context(name, %__MODULE__.Evaluations{} = snapshot) when is_atom(name) do
    PostHog.set_context(name, __MODULE__.Evaluations.event_properties(snapshot))
  end

  defp translate_flag_keys(%{flag_keys: nil} = body), do: Map.delete(body, :flag_keys)

  defp translate_flag_keys(%{flag_keys: flag_keys} = body) when is_list(flag_keys) do
    body
    |> Map.delete(:flag_keys)
    |> Map.put(:flag_keys_to_evaluate, flag_keys)
  end

  defp translate_flag_keys(body), do: body

  defp translate_disable_geoip(%{disable_geoip: disable_geoip} = body) do
    body
    |> Map.delete(:disable_geoip)
    |> Map.put(:geoip_disable, disable_geoip)
  end

  defp translate_disable_geoip(body), do: body

  @deprecated "Use PostHog.FeatureFlags.evaluate_flags/2 with PostHog.FeatureFlags.Evaluations.enabled?/2 or get_flag/2"
  @doc false
  def check(flag_name, distinct_id_or_body) when not is_atom(flag_name),
    do: check(PostHog, flag_name, distinct_id_or_body)

  @deprecated "Use PostHog.FeatureFlags.evaluate_flags/2 with PostHog.FeatureFlags.Evaluations.enabled?/2 or get_flag/2"
  @doc """
  Checks feature flag

  > #### Deprecated {: .warning}
  >
  > Use `PostHog.FeatureFlags.evaluate_flags/2` plus
  > `PostHog.FeatureFlags.Evaluations.enabled?/2` or
  > `PostHog.FeatureFlags.Evaluations.get_flag/2` instead. The snapshot lets
  > one `/flags` call serve multiple flag checks plus event enrichment.

  If there is a variant assigned, returns `{:ok, variant}`. Otherwise, `{:ok,
  true}` or `{:ok, false}`.

  Accepts an optional `distinct_id` or a map with request body. If neither is
  passed, attempts to read `distinct_id` from the context.

  This function will also
  [send](https://posthog.com/docs/api/flags#step-3-send-a-feature_flag_called-event)
  `$feature_flag_called` event and
  [set](https://posthog.com/docs/api/flags#step-2-include-feature-flag-information-when-capturing-events)
  `$feature/feature-flag-name` property in context.

  ## Examples

  Check boolean feature flag for `distinct_id`:

      iex> PostHog.FeatureFlags.check("example-feature-flag-1", "user123")
      {:ok, true}

  Check multivariant feature flag for `distinct_id` in the current context:

      iex> PostHog.set_context(%{distinct_id: "user123"})
      iex> PostHog.FeatureFlags.check("example-feature-flag-1")
      {:ok, "variant1"}

  Check boolean feature flag through a named PostHog instance:

      PostHog.FeatureFlags.check(MyPostHog, "example-feature-flag-1", "user123")
  """
  @spec check(PostHog.supervisor_name(), String.t(), PostHog.distinct_id() | map() | nil) ::
          {:ok, boolean()} | {:ok, String.t()} | {:error, Exception.t()}
  def check(name \\ PostHog, flag_name, distinct_id_or_body \\ nil) do
    case evaluate_flag(name, flag_name, distinct_id_or_body, []) do
      {:ok, %__MODULE__.Result{} = flag_result, _body} ->
        {:ok, __MODULE__.Result.value(flag_result)}

      {:ok, nil, body} ->
        {:error,
         %PostHog.UnexpectedResponseError{
           response: body,
           message: "Feature flag #{flag_name} was not found in the response"
         }}

      {:error, reason, _body} ->
        {:error, reason}
    end
  end

  @deprecated "Use PostHog.FeatureFlags.evaluate_flags/2 with PostHog.FeatureFlags.Evaluations"
  @doc false
  def get_feature_flag_result(flag_name, distinct_id_or_body)
      when not is_atom(flag_name) and not is_list(distinct_id_or_body),
      do: get_feature_flag_result(PostHog, flag_name, distinct_id_or_body, [])

  @deprecated "Use PostHog.FeatureFlags.evaluate_flags/2 with PostHog.FeatureFlags.Evaluations"
  @doc false
  def get_feature_flag_result(flag_name, distinct_id_or_body, opts)
      when not is_atom(flag_name) and is_list(opts),
      do: get_feature_flag_result(PostHog, flag_name, distinct_id_or_body, opts)

  @deprecated "Use PostHog.FeatureFlags.evaluate_flags/2 with PostHog.FeatureFlags.Evaluations"
  @doc """
  Gets the full feature flag result including value and payload.

  > #### Deprecated {: .warning}
  >
  > Use `PostHog.FeatureFlags.evaluate_flags/2` and access flags from the
  > returned `PostHog.FeatureFlags.Evaluations` snapshot. The snapshot
  > exposes the same metadata (id, version, reason, payload) plus filter
  > helpers and capture enrichment via `set_in_context/2`.

  Returns `{:ok, %PostHog.FeatureFlags.Result{}}` on success, `{:ok, nil}` if the flag
  is not found, or `{:error, reason}` on failure.

  The `PostHog.FeatureFlags.Result` struct contains:
  - `key` - The flag name
  - `enabled` - Whether the flag is enabled
  - `variant` - The variant string (nil for boolean flags)
  - `payload` - The JSON payload configured for the flag (nil if not set)

  By default, this function will
  [send](https://posthog.com/docs/api/flags#step-3-send-a-feature_flag_called-event)
  a `$feature_flag_called` event and
  [set](https://posthog.com/docs/api/flags#step-2-include-feature-flag-information-when-capturing-events)
  the `$feature/feature-flag-name` property in context.

  ## Options

  - `:send_event` - Whether to send the `$feature_flag_called` event. Defaults to `true`.

  ## Examples

  Get feature flag result for `distinct_id`:

      iex> PostHog.FeatureFlags.get_feature_flag_result("example-feature-flag-1", "user123")
      {:ok, %PostHog.FeatureFlags.Result{key: "example-feature-flag-1", enabled: true, variant: nil, payload: nil}}

  Get feature flag result with payload:

      iex> PostHog.FeatureFlags.get_feature_flag_result("feature-with-payload", "user123")
      {:ok, %PostHog.FeatureFlags.Result{key: "feature-with-payload", enabled: true, variant: "variant1", payload: %{"key" => "value"}}}

  Get feature flag result without sending event:

      iex> PostHog.FeatureFlags.get_feature_flag_result("my-flag", "user123", send_event: false)
      {:ok, %PostHog.FeatureFlags.Result{key: "my-flag", enabled: true, variant: nil, payload: nil}}

  Flag not found returns `{:ok, nil}`:

      iex> PostHog.FeatureFlags.get_feature_flag_result("non-existent-flag", "user123")
      {:ok, nil}

  Get feature flag result for `distinct_id` in the current context:

      iex> PostHog.set_context(%{distinct_id: "user123"})
      iex> PostHog.FeatureFlags.get_feature_flag_result("example-feature-flag-1")
      {:ok, %PostHog.FeatureFlags.Result{key: "example-feature-flag-1", enabled: true, variant: nil, payload: nil}}

  Get feature flag result through a named PostHog instance:

      PostHog.FeatureFlags.get_feature_flag_result(MyPostHog, "example-feature-flag-1", "user123")
  """
  @spec get_feature_flag_result(
          PostHog.supervisor_name(),
          String.t(),
          PostHog.distinct_id() | map() | nil,
          keyword()
        ) ::
          {:ok, __MODULE__.Result.t() | nil} | {:error, Exception.t()}
  def get_feature_flag_result(name \\ PostHog, flag_name, distinct_id_or_body \\ nil, opts \\ []) do
    case evaluate_flag(name, flag_name, distinct_id_or_body, opts) do
      {:ok, %__MODULE__.Result{} = result, _body} -> {:ok, result}
      {:ok, nil, _body} -> {:ok, nil}
      {:error, reason, _body} -> {:error, reason}
    end
  end

  @deprecated "Use PostHog.FeatureFlags.evaluate_flags/2 with PostHog.FeatureFlags.Evaluations"
  @doc false
  def get_feature_flag_result!(flag_name, distinct_id_or_body)
      when not is_atom(flag_name) and not is_list(distinct_id_or_body),
      do: get_feature_flag_result!(PostHog, flag_name, distinct_id_or_body, [])

  @deprecated "Use PostHog.FeatureFlags.evaluate_flags/2 with PostHog.FeatureFlags.Evaluations"
  @doc false
  def get_feature_flag_result!(flag_name, distinct_id_or_body, opts)
      when not is_atom(flag_name) and is_list(opts),
      do: get_feature_flag_result!(PostHog, flag_name, distinct_id_or_body, opts)

  @deprecated "Use PostHog.FeatureFlags.evaluate_flags/2 with PostHog.FeatureFlags.Evaluations"
  @doc """
  Gets the full feature flag result or raises on error.

  > #### Deprecated {: .warning}
  >
  > Use `PostHog.FeatureFlags.evaluate_flags/2` and access flags from the
  > returned `PostHog.FeatureFlags.Evaluations` snapshot.

  This is a wrapper around `get_feature_flag_result/4` that returns the result
  directly or raises an exception on error. This follows the Elixir convention
  where functions ending with `!` raise exceptions instead of returning error
  tuples.

  Returns `nil` if the flag is not found (does not raise), consistent with
  other PostHog SDKs.

  > **Warning**: Use this function with care as it will raise an error if there
  > are any API errors (e.g. missing `distinct_id`). For more resilient code,
  > use `get_feature_flag_result/4` which returns `{:error, reason}` instead of
  > raising.

  ## Options

  - `:send_event` - Whether to send the `$feature_flag_called` event. Defaults to `true`.

  ## Examples

  Get feature flag result for `distinct_id`:

      iex> PostHog.FeatureFlags.get_feature_flag_result!("example-feature-flag-1", "user123")
      %PostHog.FeatureFlags.Result{key: "example-feature-flag-1", enabled: true, variant: nil, payload: nil}

  Returns `nil` when flag is not found:

      iex> PostHog.FeatureFlags.get_feature_flag_result!("non-existent-flag", "user123")
      nil

  Raises an error when `distinct_id` is missing:

      iex> PostHog.FeatureFlags.get_feature_flag_result!("example-feature-flag-1")
      ** (PostHog.Error) distinct_id is required but wasn't explicitly provided or found in the context
  """
  @spec get_feature_flag_result!(
          PostHog.supervisor_name(),
          String.t(),
          PostHog.distinct_id() | map() | nil,
          keyword()
        ) ::
          __MODULE__.Result.t() | nil | no_return()
  def get_feature_flag_result!(name \\ PostHog, flag_name, distinct_id_or_body \\ nil, opts \\ []) do
    case get_feature_flag_result(name, flag_name, distinct_id_or_body, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp evaluate_flag(name, flag_name, distinct_id_or_body, opts) do
    send_event = Keyword.get(opts, :send_event, true)

    case body_for_flags(name, distinct_id_or_body) do
      {:ok, %{distinct_id: distinct_id} = body} ->
        case evaluate_single_flag(name, flag_name, body) do
          {:ok, %__MODULE__.Result{} = result, response_body} ->
            maybe_log_feature_flag_usage(
              send_event,
              name,
              distinct_id,
              result,
              evaluation_groups(body)
            )

            {:ok, result, response_body}

          {:ok, nil, response_body} ->
            {:ok, nil, response_body}

          {:error, reason} ->
            {:error, reason, nil}
        end

      {:error, reason} ->
        {:error, reason, nil}
    end
  end

  defp evaluate_single_flag(name, flag_name, body) do
    local =
      case local_evaluation_state(name, [flag_name]).definitions do
        %{flags_by_key: %{^flag_name => _flag}} = definitions ->
          __MODULE__.LocalEvaluator.evaluate(definitions, body, [flag_name])

        _definitions ->
          %{results: %{}, unresolved: MapSet.new([flag_name])}
      end

    case Map.fetch(local.results, flag_name) do
      {:ok, result} ->
        {:ok, result, %{}}

      :error ->
        evaluate_single_flag_remotely(name, flag_name, body)
    end
  end

  defp evaluate_single_flag_remotely(name, flag_name, body) do
    if Map.get(body, :only_evaluate_locally, false) == true do
      {:ok, nil, %{}}
    else
      case flags(name, Map.delete(body, :only_evaluate_locally)) do
        {:ok, %{body: %{"flags" => %{^flag_name => flag_data}} = response_body}}
        when is_map(flag_data) ->
          {:ok, build_result(flag_name, flag_data, response_body), response_body}

        {:ok, %{body: %{"flags" => _} = response_body}} ->
          {:ok, nil, response_body}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp maybe_log_feature_flag_usage(send_event, name, distinct_id, flag_result, groups) do
    if send_event do
      log_feature_flag_usage(name, distinct_id, flag_result, [], groups)
    end
  end

  @doc false
  @spec build_result(String.t(), map(), map()) :: __MODULE__.Result.t()
  def build_result(flag_name, flag_data, body) do
    {enabled, variant} = extract_flag_enabled_and_variant(flag_data)

    %__MODULE__.Result{
      key: flag_name,
      enabled: enabled,
      variant: variant,
      payload: normalize_payload(get_in(flag_data, ["metadata", "payload"])),
      id: get_in(flag_data, ["metadata", "id"]),
      version: get_in(flag_data, ["metadata", "version"]),
      reason: Map.get(flag_data, "reason"),
      request_id: Map.get(body, "requestId"),
      evaluated_at: Map.get(body, "evaluatedAt"),
      has_experiment: parse_has_experiment(flag_data),
      errors_while_computing: Map.get(body, "errorsWhileComputingFlags") == true,
      minimal_flag_called_events: Map.get(body, "minimalFlagCalledEvents") == true
    }
  end

  # `nil` means the server did not report the field (older deployments); the
  # `$feature_flag_has_experiment` property is omitted in that case.
  defp parse_has_experiment(flag_data) do
    case get_in(flag_data, ["metadata", "has_experiment"]) do
      value when is_boolean(value) -> value
      _ -> nil
    end
  end

  # PostHog's `/flags` returns payloads as JSON-encoded strings (the user
  # configures them as JSON in the UI). Decode them so callers receive the
  # parsed value. Non-string or already-decoded payloads pass through as-is.
  defp normalize_payload(nil), do: nil

  defp normalize_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> decoded
      {:error, _} -> payload
    end
  end

  defp normalize_payload(payload), do: payload

  defp extract_flag_enabled_and_variant(flag_data) do
    enabled = Map.get(flag_data, "enabled", false) == true
    variant = Map.get(flag_data, "variant")
    {enabled, variant}
  end

  @deprecated "Use PostHog.FeatureFlags.evaluate_flags/2 with PostHog.FeatureFlags.Evaluations.enabled?/2 or get_flag/2"
  @doc false
  def check!(flag_name, distinct_id_or_body) when not is_atom(flag_name),
    do: check!(PostHog, flag_name, distinct_id_or_body)

  @deprecated "Use PostHog.FeatureFlags.evaluate_flags/2 with PostHog.FeatureFlags.Evaluations.enabled?/2 or get_flag/2"
  @doc """
  Checks feature flag and returns the variant or raises on error.

  > #### Deprecated {: .warning}
  >
  > Use `PostHog.FeatureFlags.evaluate_flags/2` and
  > `PostHog.FeatureFlags.Evaluations.enabled?/2` /
  > `PostHog.FeatureFlags.Evaluations.get_flag/2` instead.

  This is a wrapper around `check/3` that returns the variant directly
  or raises an exception on error. This follows the Elixir convention where
  functions ending with `!` raise exceptions instead of returning error tuples.

  > **Warning**: Use this function with care as it will raise an error if the feature flag
  > is not found or if there are any API errors. For more resilient code, use `check/3`
  > which returns `{:error, reason}` instead of raising.

  ## Examples

  Check feature flag and get the variant:

      iex> PostHog.FeatureFlags.check!("example-feature-flag-1", "user123")
      true

  Check multivariant feature flag for distinct_id in current context:

      iex> PostHog.set_context(%{distinct_id: "user123"})
      iex> PostHog.FeatureFlags.check!("example-feature-flag-1")
      "variant1"

  Check feature flag through a named PostHog instance:

      iex> PostHog.FeatureFlags.check!(MyPostHog, "example-feature-flag-1", "user123")
      false

  Raises an error when feature flag is not found:

      iex> PostHog.FeatureFlags.check!("example-feature-flag-3", "user123")
      ** (PostHog.UnexpectedResponseError) Feature flag example-feature-flag-3 was not found in the response
  """
  @spec check!(PostHog.supervisor_name(), String.t(), PostHog.distinct_id() | map() | nil) ::
          boolean() | String.t() | no_return()
  def check!(name \\ PostHog, flag_name, distinct_id_or_body \\ nil) do
    case check(name, flag_name, distinct_id_or_body) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec log_feature_flag_usage(
          PostHog.supervisor_name(),
          PostHog.distinct_id(),
          __MODULE__.Result.t()
        ) ::
          :ok | {:error, :missing_distinct_id}
  def log_feature_flag_usage(name, distinct_id, %__MODULE__.Result{} = result) do
    log_feature_flag_usage(name, distinct_id, result, [], %{})
  end

  @doc false
  @spec log_feature_flag_usage(
          PostHog.supervisor_name(),
          PostHog.distinct_id(),
          __MODULE__.Result.t(),
          [String.t()]
        ) ::
          :ok | {:error, :missing_distinct_id}
  def log_feature_flag_usage(name, distinct_id, %__MODULE__.Result{} = result, extra_errors)
      when is_list(extra_errors) do
    log_feature_flag_usage(name, distinct_id, result, extra_errors, %{})
  end

  @doc false
  @spec log_feature_flag_usage(
          PostHog.supervisor_name(),
          PostHog.distinct_id(),
          __MODULE__.Result.t(),
          [String.t()],
          map()
        ) :: :ok | {:error, :missing_distinct_id}
  def log_feature_flag_usage(
        name,
        distinct_id,
        %__MODULE__.Result{} = result,
        extra_errors,
        groups
      )
      when is_list(extra_errors) and is_map(groups) do
    flag_missing? = "flag_missing" in extra_errors
    value = if flag_missing?, do: nil, else: __MODULE__.Result.value(result)
    errors = build_error_codes(result, extra_errors)

    properties =
      %{
        "$feature/#{result.key}" => value,
        :distinct_id => distinct_id,
        :"$feature_flag" => result.key,
        :"$feature_flag_response" => value
      }
      |> maybe_put(:"$feature_flag_id", result.id)
      |> maybe_put(:"$feature_flag_version", result.version)
      |> maybe_put(:"$feature_flag_reason", result.reason)
      |> maybe_put(:"$feature_flag_request_id", result.request_id)
      |> maybe_put(:"$feature_flag_evaluated_at", result.evaluated_at)
      |> maybe_put(:"$feature_flag_payload", result.payload)
      |> maybe_put(:"$feature_flag_has_experiment", result.has_experiment)
      |> maybe_put(:"$feature_flag_error", errors)
      |> maybe_put(:"$groups", if(map_size(groups) == 0, do: nil, else: groups))
      |> Map.put(:locally_evaluated, result.locally_evaluated)

    if PostHog.FeatureFlags.CalledCache.first_seen?(name, distinct_id, result.key, value, groups) do
      capture_called_event(name, distinct_id, result, properties)
    end

    if flag_missing? do
      :ok
    else
      PostHog.set_context(name, %{"$feature/#{result.key}" => value})
    end
  end

  # Strict allowlist for minimal $feature_flag_called events, per the
  # cross-SDK contract. Both atom and string forms are kept because context
  # and global properties may use either key type.
  @minimal_event_property_atoms [
    :"$feature_flag",
    :"$feature_flag_response",
    :"$feature_flag_has_experiment",
    :"$feature_flag_id",
    :"$feature_flag_version",
    :"$feature_flag_reason",
    :"$feature_flag_request_id",
    :"$feature_flag_evaluated_at",
    :"$feature_flag_error",
    :locally_evaluated,
    :"$groups",
    :"$process_person_profile",
    :"$session_id",
    :"$lib",
    :"$lib_version",
    :"$is_server"
  ]
  @minimal_event_properties @minimal_event_property_atoms ++
                              Enum.map(@minimal_event_property_atoms, &Atom.to_string/1)

  # Sends the minimal allowlisted event only when the server gate is on and
  # the flag is known not to be linked to an experiment. Any missing signal
  # (gate absent, has_experiment unknown) falls back to the full legacy event.
  defp capture_called_event(name, distinct_id, %__MODULE__.Result{} = result, properties) do
    if result.minimal_flag_called_events and result.has_experiment == false do
      capture_minimal_called_event(name, distinct_id, properties)
    else
      PostHog.capture(name, "$feature_flag_called", properties)
    end
  end

  # Assembles properties the same way capture/3 and bare_capture/4 would
  # (context first, then global properties), then keeps only the allowlisted
  # ones so the minimal shape stays predictable regardless of context tags or
  # customer global properties.
  defp capture_minimal_called_event(name, distinct_id, properties) do
    config = PostHog.config(name)

    # before_send still runs after this projection and may re-inflate the
    # event. That's the accepted customer escape hatch; the SDK itself must
    # not enrich the event after the allowlist.
    minimal_properties =
      name
      |> PostHog.get_event_context("$feature_flag_called")
      |> Map.merge(properties)
      |> Map.merge(config.global_properties)
      |> Map.take(@minimal_event_properties)

    PostHog.capture_prepared(config, "$feature_flag_called", distinct_id, minimal_properties)
  end

  defp build_error_codes(%__MODULE__.Result{errors_while_computing: true}, extra),
    do: ["errors_while_computing_flags" | extra] |> Enum.join(",")

  defp build_error_codes(%__MODULE__.Result{}, []), do: nil
  defp build_error_codes(%__MODULE__.Result{}, extra), do: Enum.join(extra, ",")

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp body_for_flags(name, distinct_id_or_body) do
    context = PostHog.get_context(name)

    case distinct_id_or_body do
      %{distinct_id: _distinct_id} = body ->
        {:ok, body}

      %{} = body ->
        case context do
          %{distinct_id: distinct_id} -> {:ok, Map.put(body, :distinct_id, distinct_id)}
          _context -> missing_distinct_id()
        end

      nil ->
        case context do
          %{distinct_id: distinct_id} ->
            {:ok,
             context
             |> Map.take([
               :distinct_id,
               :groups,
               :person_properties,
               :group_properties,
               :device_id
             ])
             |> Map.put(:distinct_id, distinct_id)}

          _context ->
            missing_distinct_id()
        end

      distinct_id when is_binary(distinct_id) ->
        {:ok, %{distinct_id: distinct_id}}
    end
  end

  defp missing_distinct_id do
    {:error,
     %PostHog.Error{
       message: "distinct_id is required but wasn't explicitly provided or found in the context"
     }}
  end
end
