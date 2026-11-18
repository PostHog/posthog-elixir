defmodule PostHog.FeatureFlags.MissingProbeCoordinator do
  @moduledoc false

  # Coalesces concurrent `/flags` existence probes for the same missing key within
  # one node. Waiting is bounded, so a slow probe never queues other evaluations.
  #
  # Each key has at most one round. Callers that coordinate on the key join it and
  # keep its id. A round ends when a probe settles the key, or when a single
  # shared retry after an inconclusive probe is also inconclusive. Callers holding
  # an ended round's id skip the key; later callers start a new round. Ended
  # rounds are dropped, since an unknown id already counts as ended.

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
      GenServer.cast(via(name), {:done, self(), claim})
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
  def init(:ok), do: {:ok, %{owners: %{}, waiters: %{}, procs: %{}, rounds: %{}}}

  @impl GenServer
  def handle_call({:claim, keys, claim, rounds}, {pid, _tag}, state) do
    state = unwait(state, pid)
    {skipped, keys} = Enum.split_with(keys, &skip?(state, &1, rounds, pid))
    {free, in_flight} = Enum.split_with(keys, &(not Map.has_key?(state.owners, &1)))

    # A caller that waits leads nothing, so two callers can't wait on each other.
    if in_flight == [] do
      state = Enum.reduce(free, state, &lead(&2, &1, pid, claim))
      {:reply, {:led, free, joined(state, free, rounds)}, state}
    else
      state = add_members(state, keys, claim)
      state = update_proc(state, pid, &%{&1 | claims: MapSet.put(&1.claims, claim)})
      state = Enum.reduce(in_flight, state, &add_waiter(&2, &1, pid, claim))
      state = update_proc(state, pid, &%{&1 | wait: {claim, MapSet.new(in_flight)}})
      # Record every round the caller saw, including reopened free keys, so it
      # doesn't start another probe if that round ends while it waits.
      {:reply, {:wait, in_flight, skipped, joined(state, keys, rounds)}, state}
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
    state = state |> unwait_claim(pid, claim) |> remove_member(pid, claim)
    {:noreply, maybe_forget(state, pid)}
  end

  def handle_cast({:done, pid, claim}, state),
    do: {:noreply, state |> remove_member(pid, claim) |> maybe_forget(pid)}

  def handle_cast({:unwait, pid, claim}, state) do
    state = state |> unwait_claim(pid, claim) |> remove_member(pid, claim)
    {:noreply, maybe_forget(state, pid)}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    claims = state.procs |> Map.get(pid, %{claims: MapSet.new()}) |> Map.fetch!(:claims)
    state = Enum.reduce(claims, state, &remove_member(&2, pid, &1))
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

  # A round's members are the waiting calls that can still resume it, including
  # calls waiting on another key. The round keeps its shared retry only while it
  # has members.
  # Free keys get an ownerless round, so every caller of this batch shares one
  # round, and one retry, for them.
  defp add_members(state, keys, claim) do
    rounds = Enum.reduce(keys, state.rounds, &Map.put_new_lazy(&2, &1, fn -> new_round() end))
    update_members(%{state | rounds: rounds}, keys, &MapSet.put(&1, claim))
  end

  defp remove_member(state, pid, claim) do
    keys = for {key, round} <- state.rounds, MapSet.member?(round.members, claim), do: key
    state = update_members(state, keys, &MapSet.delete(&1, claim))

    case state.procs do
      %{^pid => proc} ->
        procs = Map.put(state.procs, pid, %{proc | claims: MapSet.delete(proc.claims, claim)})
        %{state | procs: procs}

      _other ->
        state
    end
  end

  # A round with no owner and no members can't be resumed, so it is dropped and
  # the next caller starts a fresh round.
  defp update_members(state, keys, fun) do
    rounds =
      Enum.reduce(keys, state.rounds, fn key, rounds ->
        case Map.fetch(rounds, key) do
          {:ok, round} -> put_round(rounds, key, %{round | members: fun.(round.members)})
          :error -> rounds
        end
      end)

    %{state | rounds: rounds}
  end

  defp put_round(rounds, key, %{owner: nil, members: members} = round) do
    if MapSet.size(members) == 0,
      do: Map.delete(rounds, key),
      else: Map.put(rounds, key, round)
  end

  defp put_round(rounds, key, round), do: Map.put(rounds, key, round)

  defp joined(state, keys, rounds) do
    Enum.reduce(keys, rounds, fn key, rounds ->
      case Map.fetch(state.rounds, key) do
        {:ok, %{id: id}} -> Map.put(rounds, key, id)
        :error -> rounds
      end
    end)
  end

  defp lead(state, key, pid, claim) do
    round = Map.get(state.rounds, key) || new_round()
    round = %{round | members: MapSet.delete(round.members, claim)}

    %{
      state
      | owners: Map.put(state.owners, key, pid),
        rounds: Map.put(state.rounds, key, %{round | owner: {pid, claim}})
    }
    |> update_proc(pid, & &1)
  end

  defp new_round,
    do: %{id: make_ref(), owner: nil, retried?: false, members: MapSet.new()}

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

    # A failed probe nobody else joined has no group to retry for, so the round
    # ends and the next batch of callers gets its own shared retry.
    members? = MapSet.size(round.members) > 0

    case {outcome, round.retried?, members?} do
      {:abandoned, _retried?, true} -> reopen(state, key, round)
      {:unresolved, false, true} -> reopen(state, key, %{round | retried?: true})
      _settled_retried_or_alone -> end_round(state, key, round)
    end
  end

  defp reopen(state, key, round) do
    round = %{round | owner: nil}
    state = %{state | rounds: Map.put(state.rounds, key, round)}
    notify_waiters(state, key, :reopened)
  end

  defp end_round(state, key, _round) do
    state = %{state | rounds: Map.delete(state.rounds, key)}
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
        %{ref: Process.monitor(pid), wait: nil, claims: MapSet.new()}
      end)

    %{state | procs: Map.put(state.procs, pid, fun.(proc))}
  end

  defp maybe_forget(state, pid) do
    leads? = Enum.any?(state.owners, fn {_key, owner} -> owner == pid end)

    case state.procs do
      %{^pid => %{ref: ref, wait: nil, claims: claims}} ->
        if leads? or MapSet.size(claims) > 0 do
          state
        else
          Process.demonitor(ref, [:flush])
          %{state | procs: Map.delete(state.procs, pid)}
        end

      _other ->
        state
    end
  end

  defp via(name), do: PostHog.Registry.via(name, __MODULE__)
end
