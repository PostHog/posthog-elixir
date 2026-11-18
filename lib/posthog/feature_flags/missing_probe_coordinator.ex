defmodule PostHog.FeatureFlags.MissingProbeCoordinator do
  @moduledoc false

  # Coalesces concurrent `/flags` existence probes for the same missing key within
  # one node. Waiting is bounded, so a slow probe never queues other evaluations.

  use GenServer

  @wait_timeout_ms 2_000
  @call_timeout_ms 1_000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [Keyword.fetch!(opts, :supervisor_name)]}
    }
  end

  def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: via(name))

  @spec run(PostHog.supervisor_name(), [String.t()], (-> result)) :: result when result: var
  def run(name, keys, callback) do
    led = await_overlapping_probes(name, Enum.uniq(keys))

    try do
      callback.()
    after
      if led != [], do: GenServer.cast(via(name), {:release, self(), led})
    end
  end

  defp await_overlapping_probes(name, keys) do
    reply_to = Process.alias()

    try do
      claim_until_led(name, keys, reply_to, deadline())
    after
      Process.unalias(reply_to)
      flush_settled(reply_to)
    end
  end

  defp claim_until_led(name, keys, reply_to, deadline) do
    case request_claim(name, keys, reply_to) do
      {led, []} ->
        led

      {[], waiting} ->
        case await_settled(reply_to, MapSet.new(waiting), deadline) do
          :ok -> claim_until_led(name, keys, reply_to, deadline)
          :timeout -> []
        end
    end
  end

  defp flush_settled(reply_to) do
    receive do
      {^reply_to, :settled, _key} -> flush_settled(reply_to)
    after
      0 -> :ok
    end
  end

  defp request_claim(name, keys, reply_to) do
    GenServer.call(via(name), {:claim, keys, reply_to}, @call_timeout_ms)
  catch
    :exit, _reason ->
      # The claim may have been recorded even though the reply was lost.
      GenServer.cast(via(name), {:release, self(), keys})
      {[], []}
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @wait_timeout_ms

  defp await_settled(reply_to, waiting, deadline) do
    if MapSet.size(waiting) == 0 do
      :ok
    else
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^reply_to, :settled, key} ->
          await_settled(reply_to, MapSet.delete(waiting, key), deadline)
      after
        timeout -> :timeout
      end
    end
  end

  @impl GenServer
  def init(:ok), do: {:ok, %{owners: %{}, waiters: %{}, monitors: %{}}}

  @impl GenServer
  def handle_call({:claim, keys, reply_to}, {pid, _tag}, state) do
    {free, in_flight} = Enum.split_with(keys, &(not Map.has_key?(state.owners, &1)))

    # A caller that must wait leads nothing, so two callers can't wait on each other.
    if in_flight == [] do
      owners = Map.new(free, &{&1, pid})
      state = %{state | owners: Map.merge(state.owners, owners)}
      state = if free == [], do: state, else: monitor_owner(state, pid)
      {:reply, {free, []}, state}
    else
      waiters =
        Enum.reduce(in_flight, state.waiters, fn key, waiters ->
          Map.update(waiters, key, [reply_to], &[reply_to | &1])
        end)

      {:reply, {[], in_flight}, %{state | waiters: waiters}}
    end
  end

  @impl GenServer
  def handle_cast({:release, pid, keys}, state), do: {:noreply, release(state, pid, keys)}

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    keys = for {key, ^pid} <- state.owners, do: key
    {:noreply, release(state, pid, keys)}
  end

  defp monitor_owner(state, pid) do
    if Map.has_key?(state.monitors, pid) do
      state
    else
      %{state | monitors: Map.put(state.monitors, pid, Process.monitor(pid))}
    end
  end

  defp release(state, pid, keys) do
    {owners, waiters} =
      Enum.reduce(keys, {state.owners, state.waiters}, fn key, {owners, waiters} ->
        if Map.get(owners, key) == pid do
          {key_waiters, waiters} = Map.pop(waiters, key, [])
          Enum.each(key_waiters, &send(&1, {&1, :settled, key}))
          {Map.delete(owners, key), waiters}
        else
          {owners, waiters}
        end
      end)

    monitors =
      if Enum.any?(owners, fn {_key, owner} -> owner == pid end) do
        state.monitors
      else
        {ref, monitors} = Map.pop(state.monitors, pid)
        if ref, do: Process.demonitor(ref, [:flush])
        monitors
      end

    %{state | owners: owners, waiters: waiters, monitors: monitors}
  end

  defp via(name), do: PostHog.Registry.via(name, __MODULE__)
end
