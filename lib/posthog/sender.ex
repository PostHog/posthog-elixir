defmodule PostHog.Sender do
  @moduledoc false
  use GenServer

  defstruct [
    :registry,
    :index,
    :api_client,
    :max_batch_time_ms,
    :max_batch_events,
    :timer_ref,
    events: [],
    num_events: 0
  ]

  def start_link(opts) do
    name =
      opts
      |> Keyword.fetch!(:supervisor_name)
      |> PostHog.Registry.via(__MODULE__, opts[:index])

    callers = Process.get(:"$callers", [])
    Process.flag(:trap_exit, true)

    GenServer.start_link(__MODULE__, {opts, callers}, name: name)
  end

  # Client

  def send(event, supervisor_name) do
    case senders(supervisor_name) do
      [] ->
        :ok

      senders ->
        supervisor_name
        |> PostHog.Registry.config()
        |> case do
          %{test_mode: true} ->
            PostHog.Test.remember_event(supervisor_name, event)

          _ ->
            send_to_sender(event, senders)
        end
    end
  end

  defp senders(supervisor_name) do
    registry = PostHog.Registry.registry_name(supervisor_name)

    if Process.whereis(registry) do
      Registry.select(registry, [{{{__MODULE__, :_}, :"$1", :"$2"}, [], [{{:"$2", :"$1"}}]}])
    else
      []
    end
  rescue
    ArgumentError -> []
  end

  defp send_to_sender(event, senders) do
    # Pick the first available sender, otherwise random busy one.
    senders
    |> Keyword.get_lazy(:available, fn ->
      senders |> Keyword.values() |> Enum.random()
    end)
    |> GenServer.cast({:event, event})
  end

  # Callbacks

  @impl GenServer
  def init({opts, callers}) do
    state = %__MODULE__{
      registry: PostHog.Registry.registry_name(opts[:supervisor_name]),
      index: Keyword.fetch!(opts, :index),
      api_client: Keyword.fetch!(opts, :api_client),
      max_batch_time_ms: Keyword.fetch!(opts, :max_batch_time_ms),
      max_batch_events: Keyword.fetch!(opts, :max_batch_events),
      events: [],
      num_events: 0
    }

    Process.put(:"$callers", callers)

    {:available, nil} =
      Registry.update_value(state.registry, registry_key(state.index), fn _ -> :available end)

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:event, event}, state) do
    case state do
      %{num_events: n, events: events} when n + 1 >= state.max_batch_events ->
        if state.timer_ref, do: Process.cancel_timer(state.timer_ref, async: true, info: false)

        {:noreply, %{state | events: [event | events], num_events: n + 1},
         {:continue, :send_batch}}

      %{num_events: 0, events: events} ->
        ref = :erlang.start_timer(state.max_batch_time_ms, self(), :batch_time_reached)

        {:noreply, %{state | events: [event | events], num_events: 1, timer_ref: ref}}

      %{num_events: n, events: events} ->
        {:noreply, %{state | events: [event | events], num_events: n + 1}}
    end
  end

  @impl GenServer
  def handle_info({:timeout, ref, :batch_time_reached}, %{num_events: n, timer_ref: ref} = state)
      when n > 0 do
    {:noreply, state, {:continue, :send_batch}}
  end

  def handle_info({:timeout, _ref, :batch_time_reached}, state), do: {:noreply, state}

  @impl GenServer
  def handle_continue(:send_batch, state) do
    # Before we initiate an HTTP request that might block the process
    # for a potentially noticeable time, we signal to the outside world that this
    # sender is currently busy and if there is another sender available it
    # should be used instead.
    Registry.update_value(state.registry, registry_key(state.index), fn _ -> :busy end)
    PostHog.API.batch(state.api_client, state.events)
    Registry.update_value(state.registry, registry_key(state.index), fn _ -> :available end)
    {:noreply, %{state | events: [], num_events: 0, timer_ref: nil}}
  end

  @impl GenServer
  def terminate(_reason, %{num_events: n} = state) when n > 0 do
    PostHog.API.batch(state.api_client, state.events)
  end

  def terminate(_reason, _state), do: :ok

  defp registry_key(index), do: {__MODULE__, index}
end
