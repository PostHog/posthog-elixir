defmodule PostHog.Sender do
  @moduledoc false
  use GenServer

  @retryable_statuses [408, 500, 502, 503, 504]
  @initial_retry_delay_ms 1_000
  @max_retry_delay_ms 30_000

  defstruct [
    :registry,
    :index,
    :api_client,
    :max_batch_time_ms,
    :max_batch_events,
    :max_retries,
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
      %{test_mode: true} ->
        PostHog.Test.remember_event(supervisor_name, event)

      _ ->
        senders =
          supervisor_name
          |> PostHog.Registry.registry_name()
          |> Registry.select([{{{__MODULE__, :_}, :"$1", :"$2"}, [], [{{:"$2", :"$1"}}]}])

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
      max_retries: Keyword.get(opts, :max_retries, 3),
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
    send_with_retries(state.api_client, state.events, state.max_retries)
    Registry.update_value(state.registry, registry_key(state.index), fn _ -> :available end)
    {:noreply, %{state | events: [], num_events: 0}}
  end

  @impl GenServer
  def terminate(_reason, %{num_events: n} = state) when n > 0 do
    PostHog.API.batch(state.api_client, state.events)
  end

  def terminate(_reason, _state), do: :ok

  defp send_with_retries(api_client, events, max_retries, attempt \\ 0)

  defp send_with_retries(_api_client, _events, max_retries, attempt)
       when attempt > max_retries,
       do: :ok

  defp send_with_retries(api_client, events, max_retries, attempt) do
    case PostHog.API.batch(api_client, events) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status} = response} when status in @retryable_statuses ->
        delay = retry_delay(attempt, response)
        Process.sleep(delay)
        send_with_retries(api_client, events, max_retries, attempt + 1)

      {:error, _reason} ->
        delay = retry_delay(attempt, nil)
        Process.sleep(delay)
        send_with_retries(api_client, events, max_retries, attempt + 1)

      _other ->
        :ok
    end
  end

  defp retry_delay(attempt, %Req.Response{} = response) do
    case Req.Response.get_retry_after(response) do
      nil -> exponential_backoff(attempt)
      delay_ms -> delay_ms
    end
  end

  defp retry_delay(attempt, %{headers: %{"retry-after" => [value | _]}}) do
    case Integer.parse(value) do
      {seconds, ""} -> :timer.seconds(seconds)
      _ -> exponential_backoff(attempt)
    end
  end

  defp retry_delay(attempt, _response), do: exponential_backoff(attempt)

  defp exponential_backoff(attempt) do
    import Bitwise
    min(@initial_retry_delay_ms * (1 <<< attempt), @max_retry_delay_ms)
  end

  defp registry_key(index), do: {__MODULE__, index}
end
