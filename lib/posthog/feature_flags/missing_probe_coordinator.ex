defmodule PostHog.FeatureFlags.MissingProbeCoordinator do
  @moduledoc false

  # Coalesces concurrent `/flags` existence probes for the same missing key within
  # one node. Waiting is bounded, so a slow probe never queues other evaluations.
  #
  # Each key has at most one round. Callers that coordinate on the key join it and
  # keep its id. A round ends when a probe settles the key, or when a single
  # shared retry after an inconclusive probe is also inconclusive. Callers holding
  # an ended round's id skip the key; later callers start a new round.

  use GenServer

  @wait_timeout_ms 2_000
  @call_timeout_ms 1_000
  @round_ttl_ms @wait_timeout_ms + @call_timeout_ms

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [Keyword.fetch!(opts, :supervisor_name)]}
    }
  end

  def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: via(name))

  @doc """
  Runs `callback` with the keys whose probe this caller leads. Keys settled by
  another caller's probe, or not claimed in time, are not led.

  The callback returns `{result, unresolved}`, where `unresolved` lists led keys
  whose existence the probe did not establish.
  """
  @spec run(
          PostHog.supervisor_name(),
          [String.t()],
          ([String.t()] -> {result, [String.t()]})
        ) :: result
        when result: var
  def run(name, keys, callback) do
    claim = Process.alias()

    try do
      led = claim_until_led(name, Enum.uniq(keys), claim, deadline(), %{})
      run_led(name, claim, led, callback)
    after
      Process.unalias(claim)
      flush_notices(claim)
    end
  end

  defp run_led(name, claim, led, callback) do
    {result, unresolved} =
      try do
        callback.(led)
      catch
        kind, reason ->
          release(name, claim, Map.new(led, &{&1, :abandoned}))
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    unresolved = MapSet.new(unresolved)

    outcomes =
      Map.new(led, &{&1, if(MapSet.member?(unresolved, &1), do: :unresolved, else: :settled)})

    release(name, claim, outcomes)
    result
  end

  defp release(_name, _claim, outcomes) when map_size(outcomes) == 0, do: :ok

  defp release(name, claim, outcomes),
    do: GenServer.cast(via(name), {:release, self(), claim, outcomes})

  # `rounds` maps each key to the round this caller joined, so it never joins a
  # later round for a key whose round already ended.
  defp claim_until_led(_name, [], _claim, _deadline, _rounds), do: []

  defp claim_until_led(name, keys, claim, deadline, rounds) do
    case remaining(deadline) do
      0 -> give_up(name, claim)
      remaining -> claim_within(name, keys, claim, deadline, rounds, remaining)
    end
  end

  defp claim_within(name, keys, claim, deadline, rounds, remaining) do
    case request_claim(name, keys, claim, rounds, min(remaining, @call_timeout_ms)) do
      {:led, led, _rounds} ->
        led

      {:wait, waiting, skipped, rounds} ->
        keys = keys -- skipped

        case await_notices(claim, MapSet.new(waiting), [], deadline) do
          {:ok, settled} -> claim_until_led(name, keys -- settled, claim, deadline, rounds)
          :timeout -> give_up(name, claim)
        end
    end
  end

  defp give_up(name, claim) do
    GenServer.cast(via(name), {:unwait, self(), claim})
    []
  end

  defp request_claim(name, keys, claim, rounds, timeout) do
    GenServer.call(via(name), {:claim, keys, claim, rounds}, timeout)
  catch
    :exit, _reason ->
      # The claim may have been recorded even though the reply was lost.
      GenServer.cast(via(name), {:abandon_claim, self(), claim})
      {:led, [], rounds}
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @wait_timeout_ms

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp await_notices(claim, waiting, settled, deadline) do
    if MapSet.size(waiting) == 0 do
      {:ok, settled}
    else
      receive do
        {^claim, :settled, key} ->
          await_notices(claim, MapSet.delete(waiting, key), [key | settled], deadline)

        {^claim, :reopened, key} ->
          await_notices(claim, MapSet.delete(waiting, key), settled, deadline)
      after
        remaining(deadline) -> :timeout
      end
    end
  end

  defp flush_notices(claim) do
    receive do
      {^claim, _notice, _key} -> flush_notices(claim)
    after
      0 -> :ok
    end
  end

  @impl GenServer
  def init(:ok), do: {:ok, %{owners: %{}, waiters: %{}, procs: %{}, rounds: %{}, ended: %{}}}

  @impl GenServer
  def handle_call({:claim, keys, claim, rounds}, {pid, _tag}, state) do
    state = state |> unwait(pid) |> prune()
    {skipped, keys} = Enum.split_with(keys, &skip?(state, &1, rounds, pid))
    {free, in_flight} = Enum.split_with(keys, &(not Map.has_key?(state.owners, &1)))

    # A caller that waits leads nothing, so two callers can't wait on each other.
    if in_flight == [] do
      state = Enum.reduce(free, state, &lead(&2, &1, pid, claim))
      {:reply, {:led, free, joined(state, free, rounds)}, state}
    else
      state = Enum.reduce(in_flight, state, &add_waiter(&2, &1, pid, claim))
      state = update_proc(state, pid, &%{&1 | wait: {claim, MapSet.new(in_flight)}})
      {:reply, {:wait, in_flight, skipped, joined(state, in_flight, rounds)}, state}
    end
  end

  @impl GenServer
  def handle_cast({:release, pid, claim, outcomes}, state) do
    state =
      Enum.reduce(outcomes, state, fn {key, outcome}, state ->
        if owned_by?(state, key, pid, claim), do: end_probe(state, key, outcome), else: state
      end)

    {:noreply, maybe_forget(state, pid)}
  end

  def handle_cast({:abandon_claim, pid, claim}, state) do
    keys = for {key, %{owner: {^pid, ^claim}}} <- state.rounds, do: key
    state = Enum.reduce(keys, state, &end_probe(&2, &1, :abandoned))
    {:noreply, state |> unwait_claim(pid, claim) |> maybe_forget(pid)}
  end

  def handle_cast({:unwait, pid, claim}, state),
    do: {:noreply, state |> unwait_claim(pid, claim) |> maybe_forget(pid)}

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    keys = for {key, %{owner: {^pid, _claim}}} <- state.rounds, do: key
    state = Enum.reduce(keys, state, &end_probe(&2, &1, :abandoned))
    state = unwait(state, pid)
    {:noreply, %{state | procs: Map.delete(state.procs, pid)}}
  end

  # A key is skipped when the caller already leads it, or when the round the
  # caller joined has ended or been replaced.
  defp skip?(state, key, rounds, pid) do
    case {Map.fetch(rounds, key), Map.get(state.rounds, key)} do
      {_joined, %{owner: {^pid, _claim}}} -> true
      {:error, _round} -> false
      {{:ok, id}, %{id: id}} -> false
      {{:ok, _id}, _round} -> true
    end
  end

  defp joined(state, keys, rounds),
    do: Enum.reduce(keys, rounds, &Map.put(&2, &1, state.rounds[&1].id))

  defp lead(state, key, pid, claim) do
    round = Map.get(state.rounds, key) || new_round()

    %{
      state
      | owners: Map.put(state.owners, key, pid),
        rounds: Map.put(state.rounds, key, %{round | owner: {pid, claim}})
    }
    |> update_proc(pid, & &1)
  end

  defp new_round,
    do: %{id: make_ref(), owner: nil, retried?: false, expires_at: expires_at()}

  defp expires_at, do: System.monotonic_time(:millisecond) + @round_ttl_ms

  defp add_waiter(state, key, pid, claim) do
    waiters = Map.update(state.waiters, key, %{claim => pid}, &Map.put(&1, claim, pid))
    %{state | waiters: waiters}
  end

  defp owned_by?(state, key, pid, claim),
    do: match?(%{owner: {^pid, ^claim}}, Map.get(state.rounds, key))

  # An inconclusive probe gets one shared retry: the round reopens and its waiters
  # claim it again. An abandoned probe reopens without using up that retry.
  defp end_probe(state, key, outcome) do
    round = Map.fetch!(state.rounds, key)
    state = %{state | owners: Map.delete(state.owners, key)}

    case {outcome, round.retried?} do
      {:abandoned, _retried?} -> reopen(state, key, round)
      {:unresolved, false} -> reopen(state, key, %{round | retried?: true})
      _settled_or_retried -> end_round(state, key, round)
    end
  end

  defp reopen(state, key, round) do
    round = %{round | owner: nil, expires_at: expires_at()}
    state = %{state | rounds: Map.put(state.rounds, key, round)}
    notify_waiters(state, key, :reopened)
  end

  defp end_round(state, key, round) do
    ended = Map.put(state.ended, {key, round.id}, expires_at())
    state = %{state | rounds: Map.delete(state.rounds, key), ended: ended}
    notify_waiters(state, key, :settled)
  end

  defp notify_waiters(state, key, notice) do
    {key_waiters, waiters} = Map.pop(state.waiters, key, %{})
    state = %{state | waiters: waiters}

    Enum.reduce(key_waiters, state, fn {claim, pid}, state ->
      send(claim, {claim, notice, key})
      state |> drop_waited_key(pid, key) |> maybe_forget(pid)
    end)
  end

  defp prune(state) do
    now = System.monotonic_time(:millisecond)

    rounds =
      Map.reject(state.rounds, fn {key, round} ->
        is_nil(round.owner) and round.expires_at < now and not Map.has_key?(state.waiters, key)
      end)

    ended = Map.reject(state.ended, fn {_key_id, expires_at} -> expires_at < now end)
    %{state | rounds: rounds, ended: ended}
  end

  defp unwait_claim(state, pid, claim) do
    case state.procs do
      %{^pid => %{wait: {^claim, _keys}}} -> unwait(state, pid)
      _other -> state
    end
  end

  defp unwait(state, pid) do
    case state.procs do
      %{^pid => %{wait: {claim, keys}}} ->
        waiters = Enum.reduce(keys, state.waiters, &remove_waiter(&2, &1, claim))

        %{state | waiters: waiters}
        |> update_proc(pid, &%{&1 | wait: nil})
        |> maybe_forget(pid)

      _other ->
        state
    end
  end

  defp drop_waited_key(state, pid, key) do
    update_proc(state, pid, fn
      %{wait: {claim, keys}} = proc ->
        keys = MapSet.delete(keys, key)
        %{proc | wait: if(MapSet.size(keys) == 0, do: nil, else: {claim, keys})}

      proc ->
        proc
    end)
  end

  defp remove_waiter(waiters, key, claim) do
    case Map.fetch(waiters, key) do
      {:ok, key_waiters} ->
        key_waiters = Map.delete(key_waiters, claim)

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
        %{ref: Process.monitor(pid), wait: nil}
      end)

    %{state | procs: Map.put(state.procs, pid, fun.(proc))}
  end

  defp maybe_forget(state, pid) do
    leads? = Enum.any?(state.owners, fn {_key, owner} -> owner == pid end)

    case state.procs do
      %{^pid => %{ref: ref, wait: nil}} when not leads? ->
        Process.demonitor(ref, [:flush])
        %{state | procs: Map.delete(state.procs, pid)}

      _other ->
        state
    end
  end

  defp via(name), do: PostHog.Registry.via(name, __MODULE__)
end
