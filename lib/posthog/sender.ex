defmodule PostHog.Sender do
  @moduledoc false
  use GenServer

  defstruct [
    :registry,
    :index,
    :api_client,
    :max_batch_time_ms,
    :max_batch_events,
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
    supervisor_name
    |> PostHog.Registry.config()
    |> case do
      %{enabled: false} ->
        :ok

      %{test_mode: true} ->
        PostHog.Test.remember_event(supervisor_name, event)

      _ ->
        send_to_sender(event, supervisor_name)
    end
  end

  defp send_to_sender(event, supervisor_name) do
    senders =
      supervisor_name
      |> PostHog.Registry.registry_name()
      |> Registry.select([{{{__MODULE__, :_}, :"$1", :"$2"}, [], [{{:"$2", :"$1"}}]}])

    case senders do
      [] ->
        :ok

      senders ->
        # Pick the first available sender, otherwise random busy one.
        senders
        |> Keyword.get_lazy(:available, fn ->
          senders |> Keyword.values() |> Enum.random()
        end)
        |> GenServer.cast({:event, event})
    end
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
        {:noreply, %{state | events: [event | events], num_events: n + 1},
         {:continue, :send_batch}}

      %{num_events: 0, events: events} ->
        Process.send_after(self(), :batch_time_reached, state.max_batch_time_ms)

        {:noreply, %{state | events: [event | events], num_events: 1}}

      %{num_events: n, events: events} ->
        {:noreply, %{state | events: [event | events], num_events: n + 1}}
    end
  end

  @impl GenServer
  def handle_info(:batch_time_reached, state) do
    {:noreply, state, {:continue, :send_batch}}
  end

  @impl GenServer
  def handle_continue(:send_batch, state) do
    # Before we initiate an HTTP request that might block the process
    # for a potentially noticeable time, we signal to the outside world that this
    # sender is currently busy and if there is another sender available it
    # should be used instead.
    Registry.update_value(state.registry, registry_key(state.index), fn _ -> :busy end)
    PostHog.API.batch(state.api_client, state.events)
    Registry.update_value(state.registry, registry_key(state.index), fn _ -> :available end)
    {:noreply, %{state | events: [], num_events: 0}}
  end

  @impl GenServer
  def terminate(_reason, %{num_events: n} = state) when n > 0 do
    PostHog.API.batch(state.api_client, state.events)
  end

  def terminate(_reason, _state), do: :ok

  defp registry_key(index), do: {__MODULE__, index}
end
