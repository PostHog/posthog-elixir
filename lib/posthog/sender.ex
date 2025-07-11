defmodule PostHog.Sender do
  @moduledoc false
  use GenServer

  defstruct [
    :registry,
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
      |> PostHog.Registry.via(__MODULE__)

    callers = Process.get(:"$callers", [])
    Process.flag(:trap_exit, true)

    GenServer.start_link(__MODULE__, {opts, callers}, name: name)
  end

  # Client

  def send(event, supervisor_name) do
    supervisor_name
    |> PostHog.Registry.via(__MODULE__)
    |> GenServer.cast({:event, event})
  end

  # Callbacks

  @impl GenServer
  def init({opts, callers}) do
    state = %__MODULE__{
      registry: PostHog.Registry.registry_name(opts[:supervisor_name]),
      api_client: Keyword.fetch!(opts, :api_client),
      max_batch_time_ms: Keyword.fetch!(opts, :max_batch_time_ms),
      max_batch_events: Keyword.fetch!(opts, :max_batch_events),
      events: [],
      num_events: 0
    }

    Process.put(:"$callers", callers)

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
    PostHog.API.post_batch(state.api_client, state.events)
    {:noreply, %{state | events: [], num_events: 0}}
  end

  @impl GenServer
  def terminate(_reason, %{num_events: n} = state) when n > 0 do
    PostHog.API.post_batch(state.api_client, state.events)
  end

  def terminate(_reason, _state), do: :ok
end
