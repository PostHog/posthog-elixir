defmodule PostHog.FeatureFlags.DefinitionLoader do
  @moduledoc false
  use GenServer

  require Logger

  defmodule Config do
    @moduledoc false
    @enforce_keys [
      :api_client,
      :api_key,
      :secret_key,
      :supervisor_name,
      :feature_flags_poll_interval_ms,
      :flag_definition_request_timeout_ms,
      :flag_definition_cache_provider_timeout_ms
    ]
    defstruct @enforce_keys ++ [flag_definition_cache_provider: nil]
  end

  defimpl Inspect, for: Config do
    import Inspect.Algebra

    def inspect(_config, _opts),
      do: concat(["#PostHog.FeatureFlags.DefinitionLoader.Config<redacted>"])
  end

  @max_quota_backoff_ms 60_000
  @negative_knowledge_capacity 1_000

  @type snapshot :: %{
          flags: [map()],
          flags_by_key: %{String.t() => map()},
          group_type_mapping: map(),
          cohorts: map(),
          minimal_flag_called_events: boolean()
        }

  def child_spec(opts) do
    config = opts |> Keyword.fetch!(:config) |> private_config()
    callers = Keyword.get(opts, :callers, [])

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [config, callers]},
      shutdown:
        config.flag_definition_request_timeout_ms +
          3 * config.flag_definition_cache_provider_timeout_ms + 1_000
    }
  end

  def start_link(%Config{} = config, callers) do
    GenServer.start_link(__MODULE__, {config, callers}, name: via(config.supervisor_name))
  end

  @spec definitions(PostHog.supervisor_name()) :: snapshot() | nil
  def definitions(name \\ PostHog), do: readable_evaluation_state(name).definitions

  @spec ready?(PostHog.supervisor_name()) :: boolean()
  def ready?(name \\ PostHog), do: not is_nil(definitions(name))

  @spec refresh(PostHog.supervisor_name()) :: :ok
  def refresh(name \\ PostHog), do: GenServer.call(via(name), :refresh, :infinity)

  @doc false
  def evaluation_state(name, keys) do
    state = readable_evaluation_state(name)

    %{
      definitions: state.definitions,
      generation: state.generation,
      known_missing: keys |> MapSet.new() |> MapSet.intersection(state.negative_keys)
    }
  end

  @doc false
  def update_negative_knowledge(name, generation, requested_keys, returned_keys, clean?) do
    GenServer.cast(
      via(name),
      {:update_negative_knowledge, generation, requested_keys, returned_keys, clean?}
    )
  end

  defp readable_evaluation_state(name) do
    state = cached_evaluation_state(name)

    if state.initial_load_complete? do
      state
    else
      try do
        GenServer.call(via(name), :cached_evaluation_state, :infinity)
      catch
        :exit, _reason -> state
      end
    end
  end

  defp cached_evaluation_state(name) do
    registry = PostHog.Registry.registry_name(name)

    case Registry.lookup(registry, __MODULE__) do
      [{_pid, %{definitions: _definitions} = state}] ->
        state

      _other ->
        empty_evaluation_state()
    end
  rescue
    ArgumentError -> empty_evaluation_state()
  end

  defp empty_evaluation_state do
    %{
      definitions: nil,
      generation: nil,
      negative_keys: MapSet.new(),
      initial_load_complete?: true
    }
  end

  defp via(name), do: PostHog.Registry.via(name, __MODULE__)

  @impl GenServer
  def init({%Config{} = config, callers}) do
    Process.flag(:trap_exit, true)
    Process.put(:"$callers", callers)

    state = %{
      definitions: nil,
      definition_generation: {make_ref(), 0},
      negative_keys: MapSet.new(),
      negative_order: [],
      etag: nil,
      loaded_at: nil,
      timer_ref: nil,
      timer_generation: 0,
      quota_backoff_ms: nil,
      initial_load_complete?: false,
      config: config
    }

    {:ok, publish_evaluation_state(state), {:continue, :initial_load}}
  end

  @impl GenServer
  def handle_continue(:initial_load, state) do
    state = state |> refresh_and_schedule() |> Map.put(:initial_load_complete?, true)
    {:noreply, publish_evaluation_state(state)}
  end

  @impl GenServer
  def handle_call(:cached_evaluation_state, _from, state),
    do: {:reply, evaluation_state_from(state), state}

  def handle_call(:definitions, _from, state), do: {:reply, state.definitions, state}
  def handle_call(:ready?, _from, state), do: {:reply, not is_nil(state.definitions), state}
  def handle_call(:refresh, _from, state), do: {:reply, :ok, refresh_and_schedule(state)}

  @impl GenServer
  def handle_cast(
        {:update_negative_knowledge, generation, requested, returned, clean?},
        %{definition_generation: generation} = state
      ) do
    state =
      state |> update_retained_missing(requested, returned, clean?) |> publish_evaluation_state()

    {:noreply, state}
  end

  def handle_cast(
        {:update_negative_knowledge, _generation, _requested, _returned, _clean?},
        state
      ),
      do: {:noreply, state}

  @impl GenServer
  def handle_info({:refresh, generation}, %{timer_generation: generation} = state),
    do: {:noreply, refresh_and_schedule(state)}

  def handle_info({:refresh, _stale_generation}, state), do: {:noreply, state}
  def handle_info({:boundary_result, _ref, _pid, _result}, state), do: {:noreply, state}
  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    cancel_timer(state.timer_ref)

    case state.config.flag_definition_cache_provider do
      {module, provider_state} ->
        case invoke_provider(state, module, :shutdown, [provider_state]) do
          {:ok, :ok} -> :ok
          result -> provider_warning(:shutdown, result)
        end

      nil ->
        :ok
    end
  end

  defp refresh_and_schedule(state) do
    state = invalidate_timer(state)

    state =
      try do
        refresh_state(state)
      rescue
        _exception ->
          warning("definition refresh failed unexpectedly; keeping stale definitions")
          state
      catch
        _kind, _reason ->
          warning("definition refresh failed unexpectedly; keeping stale definitions")
          state
      end

    state
    |> schedule_refresh()
    |> publish_evaluation_state()
  end

  defp publish_evaluation_state(state) do
    registry = PostHog.Registry.registry_name(state.config.supervisor_name)

    cached = evaluation_state_from(state)

    Registry.update_value(registry, __MODULE__, fn _old -> cached end)
    state
  end

  defp evaluation_state_from(state) do
    %{
      definitions: state.definitions,
      generation: state.definition_generation,
      negative_keys: state.negative_keys,
      initial_load_complete?: state.initial_load_complete?
    }
  end

  defp invalidate_timer(state) do
    cancel_timer(state.timer_ref)
    %{state | timer_ref: nil, timer_generation: state.timer_generation + 1}
  end

  defp schedule_refresh(state) do
    delay = state.quota_backoff_ms || state.config.feature_flags_poll_interval_ms
    generation = state.timer_generation
    timer_ref = Process.send_after(self(), {:refresh, generation}, delay)
    %{state | timer_ref: timer_ref}
  end

  defp refresh_state(%{config: %{flag_definition_cache_provider: nil}} = state),
    do: fetch_direct(state, false)

  defp refresh_state(
         %{
           config: %{flag_definition_cache_provider: {module, provider_state}}
         } = state
       ) do
    case invoke_provider(state, module, :should_fetch_flag_definitions, [provider_state]) do
      {:ok, true} ->
        fetch_direct(state, true)

      {:ok, false} ->
        read_provider_without_fetch_ownership(state, module, provider_state)

      other ->
        provider_warning(:should_fetch_flag_definitions, other)
        fetch_direct(state, true)
    end
  end

  defp read_provider_without_fetch_ownership(state, module, provider_state) do
    case invoke_provider(state, module, :get_flag_definitions, [provider_state]) do
      {:ok, nil} ->
        provider_cache_miss(state)

      {:ok, cached} ->
        case normalize_envelope(cached) do
          {:ok, snapshot, _complete} -> install(state, snapshot, nil)
          :error -> provider_read_failure(state, :malformed)
        end

      other ->
        provider_read_failure(state, other)
    end
  end

  defp provider_cache_miss(%{definitions: nil} = state), do: fetch_direct(state, false)
  defp provider_cache_miss(state), do: state

  defp provider_read_failure(state, reason) do
    provider_warning(:get_flag_definitions, reason)

    if is_nil(state.definitions) do
      fetch_direct(state, false)
    else
      state
    end
  end

  defp fetch_direct(state, store?) do
    config = state.config

    result =
      invoke_boundary(
        config.flag_definition_request_timeout_ms,
        fn ->
          PostHog.API.flag_definitions(
            config.api_client,
            config.api_key,
            config.secret_key,
            state.etag
          )
        end
      )

    response =
      case result do
        {:ok, api_result} -> api_result
        {:error, boundary_reason} -> {:error, boundary_reason}
      end

    handle_response(state, response, store?)
  end

  defp handle_response(state, {:ok, %{status: 200, body: body} = response}, store?) do
    case normalize_envelope(body) do
      {:ok, snapshot, complete} ->
        state = install(state, snapshot, response_etag(response))
        state = %{state | quota_backoff_ms: nil}
        if store?, do: store_provider(state, complete), else: state

      :error ->
        warning("definition refresh returned a malformed response; keeping stale definitions")
        state
    end
  end

  defp handle_response(state, {:ok, %{status: 304} = response}, _store?) do
    state
    |> Map.put(:etag, response_etag(response) || state.etag)
    |> successful_definition_refresh(state.definitions)
  end

  defp handle_response(state, {:ok, %{status: status}}, _store?) when status in [401, 402, 403] do
    warning("definition refresh was rejected with HTTP #{status}; clearing local definitions")
    %{state | definitions: nil, etag: nil, loaded_at: nil, quota_backoff_ms: nil}
  end

  defp handle_response(state, {:ok, %{status: 429}}, _store?) do
    warning("definition refresh was quota limited with HTTP 429; keeping stale definitions")
    %{state | quota_backoff_ms: next_quota_backoff(state)}
  end

  defp handle_response(state, {:ok, %{status: status}}, _store?) do
    warning("definition refresh failed with HTTP #{status}; keeping stale definitions")
    state
  end

  defp handle_response(state, {:error, :timeout}, _store?) do
    warning("definition refresh timed out; keeping stale definitions")
    state
  end

  defp handle_response(state, {:error, _reason}, _store?) do
    # Do not inspect custom-client failures: request terms may contain authorization headers.
    warning("definition refresh request failed; keeping stale definitions")
    state
  end

  defp handle_response(state, _other, _store?) do
    warning("definition refresh returned an unexpected response; keeping stale definitions")
    state
  end

  defp next_quota_backoff(state) do
    baseline = state.config.feature_flags_poll_interval_ms
    current = max(state.quota_backoff_ms || baseline, baseline)
    cap = max(@max_quota_backoff_ms, baseline * 8)
    current |> Kernel.*(2) |> max(baseline) |> min(cap)
  end

  defp install(state, snapshot, etag) do
    state
    |> Map.put(:etag, etag)
    |> successful_definition_refresh(snapshot)
  end

  defp successful_definition_refresh(state, snapshot) do
    %{
      state
      | definitions: snapshot,
        definition_generation: next_definition_generation(state.definition_generation),
        negative_keys: MapSet.new(),
        negative_order: [],
        loaded_at: DateTime.utc_now(),
        quota_backoff_ms: nil
    }
  end

  defp next_definition_generation({incarnation, revision}),
    do: {incarnation, revision + 1}

  defp store_provider(
         %{config: %{flag_definition_cache_provider: {module, provider_state}}} = state,
         complete
       ) do
    case invoke_provider(state, module, :on_flag_definitions_received, [provider_state, complete]) do
      {:ok, :ok} ->
        state

      other ->
        provider_warning(:on_flag_definitions_received, other)
        state
    end
  end

  defp normalize_envelope(body) when is_map(body) do
    flags = value(body, "flags")
    mapping = value(body, "group_type_mapping")
    cohorts = value(body, "cohorts")

    if is_list(flags) and is_map(mapping) and is_map(cohorts) do
      minimal = value(body, "minimal_flag_called_events") == true

      snapshot = %{
        flags: flags,
        flags_by_key:
          Map.new(Enum.filter(flags, &(is_map(&1) and is_binary(value(&1, "key")))), fn flag ->
            {value(flag, "key"), flag}
          end),
        group_type_mapping: mapping,
        cohorts: cohorts,
        minimal_flag_called_events: minimal
      }

      complete = %{
        "flags" => flags,
        "group_type_mapping" => mapping,
        "cohorts" => cohorts,
        "minimal_flag_called_events" => minimal
      }

      {:ok, snapshot, complete}
    else
      :error
    end
  end

  defp normalize_envelope(_body), do: :error

  defp value(map, "flags"), do: Map.get(map, "flags", Map.get(map, :flags))

  defp value(map, "group_type_mapping"),
    do: Map.get(map, "group_type_mapping", Map.get(map, :group_type_mapping))

  defp value(map, "cohorts"), do: Map.get(map, "cohorts", Map.get(map, :cohorts))

  defp value(map, "minimal_flag_called_events"),
    do: Map.get(map, "minimal_flag_called_events", Map.get(map, :minimal_flag_called_events))

  defp value(map, "key"), do: Map.get(map, "key", Map.get(map, :key))

  defp response_etag(%{headers: headers}), do: header_value(headers, "etag")
  defp response_etag(_response), do: nil

  defp header_value(headers, key) when is_map(headers) do
    Enum.find_value(headers, fn {name, header} ->
      if String.downcase(to_string(name)) == key, do: first_header(header)
    end)
  end

  defp header_value(headers, key) when is_list(headers) do
    Enum.find_value(headers, fn
      {name, header} -> if String.downcase(to_string(name)) == key, do: first_header(header)
      _ -> nil
    end)
  end

  defp header_value(_headers, _key), do: nil
  defp first_header([header | _]), do: header
  defp first_header(header) when is_binary(header), do: header
  defp first_header(_header), do: nil

  defp invoke_provider(state, module, callback, args) do
    invoke_boundary(
      state.config.flag_definition_cache_provider_timeout_ms,
      fn -> apply(module, callback, args) end
    )
  end

  defp invoke_boundary(timeout, callback) do
    parent = self()
    callers = Process.get(:"$callers", [])
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        result = safely_invoke(callback)
        send(parent, {:boundary_result, ref, self(), result})
      end)

    receive do
      {:boundary_result, ^ref, ^pid, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, boundary_error(reason)}
    after
      timeout ->
        Process.exit(pid, :kill)
        await_down(monitor, pid)
        drain_boundary_result(ref, pid)
        {:error, :timeout}
    end
  end

  defp safely_invoke(callback) do
    {:ok, callback.()}
  rescue
    _exception -> {:error, :exception}
  catch
    :exit, reason -> {:error, boundary_error(reason)}
    _kind, _reason -> {:error, :throw}
  end

  defp boundary_error(:normal), do: :normal
  defp boundary_error(:killed), do: :timeout
  defp boundary_error(_reason), do: :exit

  defp await_down(monitor, pid) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      100 -> Process.demonitor(monitor, [:flush])
    end
  end

  defp drain_boundary_result(ref, pid) do
    receive do
      {:boundary_result, ^ref, ^pid, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp provider_warning(callback, result) do
    reason =
      case result do
        {:error, reason} -> reason
        {:ok, unexpected} -> {:unexpected_return, unexpected}
        other -> other
      end

    warning("definition cache provider #{callback} failed (#{provider_reason(reason)})")
  end

  defp provider_reason(:timeout), do: "timeout"
  defp provider_reason(:exception), do: "exception"
  defp provider_reason(:exit), do: "exit"
  defp provider_reason(:throw), do: "throw"
  defp provider_reason(:malformed), do: "malformed data"
  defp provider_reason({:unexpected_return, _value}), do: "unexpected return"
  defp provider_reason(_reason), do: "error"

  defp update_retained_missing(state, requested, returned, clean?) do
    returned = MapSet.new(returned)

    order = Enum.reject(state.negative_order, &MapSet.member?(returned, &1))
    keys = MapSet.difference(state.negative_keys, returned)

    {order, keys} =
      if clean? do
        omissions =
          requested
          |> MapSet.new()
          |> MapSet.difference(returned)
          |> MapSet.to_list()
          |> Enum.sort()
          |> Enum.take(-@negative_knowledge_capacity)

        omission_keys = MapSet.new(omissions)
        order = Enum.reject(order, &MapSet.member?(omission_keys, &1)) ++ omissions
        {order, MapSet.union(keys, omission_keys)}
      else
        {order, keys}
      end

    overflow = max(length(order) - @negative_knowledge_capacity, 0)
    retained_order = Enum.drop(order, overflow)

    %{
      state
      | negative_order: retained_order,
        negative_keys: MapSet.intersection(keys, MapSet.new(retained_order))
    }
  end

  defp private_config(config) do
    struct!(Config, %{
      api_client: config.api_client,
      api_key: config.api_key,
      secret_key: config.secret_key,
      supervisor_name: config.supervisor_name,
      feature_flags_poll_interval_ms: config.feature_flags_poll_interval_ms,
      flag_definition_request_timeout_ms: config.flag_definition_request_timeout_ms,
      flag_definition_cache_provider_timeout_ms: config.flag_definition_cache_provider_timeout_ms,
      flag_definition_cache_provider: config.flag_definition_cache_provider
    })
  end

  defp warning(message), do: Logger.warning(message, posthog_skip_capture: true)
end
