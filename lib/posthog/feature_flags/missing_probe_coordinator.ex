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

  @doc """
  Runs `callback` with the keys whose probe this caller owns. Keys whose probe
  settled elsewhere, or that could not be claimed in time, are not owned.

  The callback returns `{result, unresolved}`, where `unresolved` lists owned keys
  whose existence the probe did not establish.
  """
  @spec run(
          PostHog.supervisor_name(),
          [String.t()],
          ([String.t()] -> {result, [String.t()]})
        ) :: result
        when result: var
  def run(name, keys, callback) do
    led = await_overlapping_probes(name, Enum.uniq(keys))

    {result, unresolved} =
      try do
        callback.(led)
      catch
        kind, reason ->
          release(name, led, :abandoned)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    unresolved = Enum.filter(unresolved, &(&1 in led))
    release(name, led -- unresolved, :settled)
    release(name, unresolved, :unresolved)
    result
  end

  defp release(_name, [], _notice), do: :ok

  defp release(name, keys, notice),
    do: GenServer.cast(via(name), {:release, self(), keys, notice})

  defp await_overlapping_probes(name, keys) do
    reply_to = Process.alias()

    try do
      claim_until_led(name, keys, reply_to, deadline())
    after
      Process.unalias(reply_to)
      flush_notices(reply_to)
    end
  end

  defp claim_until_led(_name, [], _reply_to, _deadline), do: []

  defp claim_until_led(name, keys, reply_to, deadline) do
    case remaining(deadline) do
      0 -> []
      remaining -> claim_within(name, keys, reply_to, deadline, remaining)
    end
  end

  defp claim_within(name, keys, reply_to, deadline, remaining) do
    case request_claim(name, keys, reply_to, min(remaining, @call_timeout_ms)) do
      {led, []} -> led
      {[], waiting} -> await_then_reclaim(name, keys, waiting, reply_to, deadline)
    end
  end

  defp await_then_reclaim(name, keys, waiting, reply_to, deadline) do
    case await_notices(reply_to, MapSet.new(waiting), [], deadline) do
      # Settled keys are not claimed again, so their waiters run in parallel
      # instead of queueing behind each other. Abandoned keys are claimed again.
      {:ok, settled} ->
        claim_until_led(name, keys -- settled, reply_to, deadline)

      :timeout ->
        GenServer.cast(via(name), {:unwait, self(), reply_to})
        []
    end
  end

  defp request_claim(name, keys, reply_to, timeout) do
    GenServer.call(via(name), {:claim, keys, reply_to}, timeout)
  catch
    :exit, _reason ->
      # The claim may have been recorded even though the reply was lost.
      release(name, keys, :abandoned)
      GenServer.cast(via(name), {:unwait, self(), reply_to})
      {[], []}
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @wait_timeout_ms

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp await_notices(reply_to, waiting, settled, deadline) do
    if MapSet.size(waiting) == 0 do
      {:ok, settled}
    else
      receive do
        {^reply_to, :settled, key} ->
          await_notices(reply_to, MapSet.delete(waiting, key), [key | settled], deadline)

        {^reply_to, :abandoned, key} ->
          await_notices(reply_to, MapSet.delete(waiting, key), settled, deadline)
      after
        remaining(deadline) -> :timeout
      end
    end
  end

  defp flush_notices(reply_to) do
    receive do
      {^reply_to, _notice, _key} -> flush_notices(reply_to)
    after
      0 -> :ok
    end
  end

  @impl GenServer
  def init(:ok), do: {:ok, %{owners: %{}, waiters: %{}, procs: %{}, retrying: %{}}}

  @impl GenServer
  def handle_call({:claim, keys, reply_to}, {pid, _tag}, state) do
    state = unwait(state, pid)
    {free, in_flight} = Enum.split_with(keys, &(not Map.has_key?(state.owners, &1)))

    # A caller that must wait owns nothing, so two callers can't wait on each other.
    if in_flight == [] do
      state = %{state | owners: Enum.reduce(free, state.owners, &Map.put(&2, &1, pid))}
      state = update_proc(state, pid, &%{&1 | owned: MapSet.union(&1.owned, MapSet.new(free))})
      {:reply, {free, []}, maybe_forget(state, pid)}
    else
      waiters =
        Enum.reduce(in_flight, state.waiters, fn key, waiters ->
          Map.update(waiters, key, %{reply_to => pid}, &Map.put(&1, reply_to, pid))
        end)

      state = %{state | waiters: waiters}
      state = update_proc(state, pid, &%{&1 | wait: {reply_to, MapSet.new(in_flight)}})
      {:reply, {[], in_flight}, state}
    end
  end

  @impl GenServer
  def handle_cast({:release, pid, keys, notice}, state),
    do: {:noreply, release_owned(state, pid, keys, notice)}

  def handle_cast({:unwait, pid, reply_to}, state) do
    state =
      case state.procs do
        %{^pid => %{wait: {^reply_to, _keys}}} -> unwait(state, pid)
        _other -> state
      end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Map.pop(state.procs, pid) do
      {nil, _procs} ->
        {:noreply, state}

      {proc, _procs} ->
        state = release_owned(state, pid, MapSet.to_list(proc.owned), :abandoned)
        state = unwait(state, pid)
        {:noreply, %{state | procs: Map.delete(state.procs, pid)}}
    end
  end

  defp release_owned(state, pid, keys, notice) do
    state =
      Enum.reduce(keys, state, fn key, state ->
        if Map.get(state.owners, key) == pid,
          do: release_key(state, key, notice),
          else: state
      end)

    state
    |> update_proc(pid, &%{&1 | owned: MapSet.difference(&1.owned, MapSet.new(keys))})
    |> maybe_forget(pid)
  end

  defp release_key(state, key, notice) do
    {key_waiters, waiters} = Map.pop(state.waiters, key, %{})
    state = %{state | owners: Map.delete(state.owners, key), waiters: waiters}
    {notice, state} = retry_notice(state, key, notice, map_size(key_waiters) > 0)

    Enum.reduce(key_waiters, state, fn {reply_to, waiter}, state ->
      send(reply_to, {reply_to, notice, key})
      state |> drop_waited_key(waiter, key) |> maybe_forget(waiter)
    end)
  end

  # An unresolved probe hands the key to one waiter for a single retry, so a
  # transient error doesn't send every waiter to `/flags`. If the retry is also
  # unresolved, the remaining waiters proceed together instead of queueing.
  defp retry_notice(state, key, notice, waiters?) do
    state = prune_retrying(state)
    retried? = Map.has_key?(state.retrying, key)

    cond do
      notice == :unresolved and waiters? and not retried? ->
        expires_at = System.monotonic_time(:millisecond) + @wait_timeout_ms
        {:abandoned, %{state | retrying: Map.put(state.retrying, key, expires_at)}}

      notice == :abandoned and waiters? ->
        {:abandoned, state}

      true ->
        {:settled, %{state | retrying: Map.delete(state.retrying, key)}}
    end
  end

  defp prune_retrying(%{retrying: retrying} = state) when map_size(retrying) == 0, do: state

  defp prune_retrying(state) do
    now = System.monotonic_time(:millisecond)

    retrying =
      Map.reject(state.retrying, fn {key, expires_at} ->
        expires_at < now and not Map.has_key?(state.owners, key)
      end)

    %{state | retrying: retrying}
  end

  defp unwait(state, pid) do
    case state.procs do
      %{^pid => %{wait: {reply_to, keys}}} ->
        waiters = Enum.reduce(keys, state.waiters, &remove_waiter(&2, &1, reply_to))

        %{state | waiters: waiters}
        |> update_proc(pid, &%{&1 | wait: nil})
        |> maybe_forget(pid)

      _other ->
        state
    end
  end

  defp drop_waited_key(state, pid, key) do
    update_proc(state, pid, fn
      %{wait: {reply_to, keys}} = proc ->
        keys = MapSet.delete(keys, key)
        %{proc | wait: if(MapSet.size(keys) == 0, do: nil, else: {reply_to, keys})}

      proc ->
        proc
    end)
  end

  defp remove_waiter(waiters, key, reply_to) do
    case Map.fetch(waiters, key) do
      {:ok, key_waiters} ->
        key_waiters = Map.delete(key_waiters, reply_to)

        if map_size(key_waiters) == 0,
          do: Map.delete(waiters, key),
          else: Map.put(waiters, key, key_waiters)

      :error ->
        waiters
    end
  end

  defp update_proc(state, pid, fun) do
    proc =
      Map.get_lazy(state.procs, pid, fn ->
        %{ref: Process.monitor(pid), owned: MapSet.new(), wait: nil}
      end)

    %{state | procs: Map.put(state.procs, pid, fun.(proc))}
  end

  defp maybe_forget(state, pid) do
    case state.procs do
      %{^pid => %{ref: ref, wait: nil, owned: owned}} ->
        if MapSet.size(owned) == 0 do
          Process.demonitor(ref, [:flush])
          %{state | procs: Map.delete(state.procs, pid)}
        else
          state
        end

      _other ->
        state
    end
  end

  defp via(name), do: PostHog.Registry.via(name, __MODULE__)
end
