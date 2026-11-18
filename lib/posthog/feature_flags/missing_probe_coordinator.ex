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
  whose existence the probe did not establish. Those keys are handed to one waiting
  caller for a single retry per group of waiters.
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
      claim_until_led(name, keys, reply_to, deadline(), %{})
    after
      Process.unalias(reply_to)
      flush_notices(reply_to)
    end
  end

  # `retried` maps keys to the shared retry this caller was assigned to, so a
  # finished retry is never followed by another one for the same caller.
  defp claim_until_led(_name, [], _reply_to, _deadline, _retried), do: []

  defp claim_until_led(name, keys, reply_to, deadline, retried) do
    case remaining(deadline) do
      0 -> give_up(name, reply_to)
      remaining -> claim_within(name, keys, reply_to, deadline, remaining, retried)
    end
  end

  # Stops waiting and passes on any key the coordinator handed over meanwhile.
  defp give_up(name, reply_to) do
    GenServer.cast(via(name), {:unwait, self(), reply_to})
    []
  end

  defp claim_within(name, keys, reply_to, deadline, remaining, retried) do
    case request_claim(name, keys, reply_to, retried, min(remaining, @call_timeout_ms)) do
      {led, []} -> led
      {[], waiting} -> await_then_reclaim(name, keys, waiting, reply_to, deadline, retried)
    end
  end

  defp await_then_reclaim(name, keys, waiting, reply_to, deadline, retried) do
    case await_notices(reply_to, MapSet.new(waiting), {[], retried}, deadline) do
      # Settled keys are not claimed again, so their waiters run in parallel
      # instead of queueing behind each other. Abandoned keys are claimed again.
      {:ok, {settled, retried}} ->
        claim_until_led(name, keys -- settled, reply_to, deadline, retried)

      :timeout ->
        give_up(name, reply_to)
    end
  end

  defp request_claim(name, keys, reply_to, retried, timeout) do
    GenServer.call(via(name), {:claim, keys, reply_to, retried}, timeout)
  catch
    :exit, _reason ->
      # The claim may have been recorded even though the reply was lost.
      release(name, keys, :abandoned)
      GenServer.cast(via(name), {:unwait, self(), reply_to})
      {[], []}
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @wait_timeout_ms

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp await_notices(reply_to, waiting, {settled, retried} = acc, deadline) do
    if MapSet.size(waiting) == 0 do
      {:ok, acc}
    else
      receive do
        {^reply_to, :settled, key} ->
          acc = {[key | settled], retried}
          await_notices(reply_to, MapSet.delete(waiting, key), acc, deadline)

        {^reply_to, {:retry, token}, key} ->
          acc = {settled, Map.put(retried, key, token)}
          await_notices(reply_to, MapSet.delete(waiting, key), acc, deadline)

        {^reply_to, notice, key} when notice in [:granted, :abandoned] ->
          await_notices(reply_to, MapSet.delete(waiting, key), acc, deadline)
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
  def init(:ok), do: {:ok, %{owners: %{}, waiters: %{}, procs: %{}, retries: %{}}}

  @impl GenServer
  def handle_call({:claim, keys, reply_to, retried}, {pid, _tag}, state) do
    state = state |> unwait(pid) |> prune_retries()
    keys = Enum.reject(keys, &finished_retry?(state, &1, retried))
    {mine, others} = Enum.split_with(keys, &(Map.get(state.owners, &1) == pid))
    {free, in_flight} = Enum.split_with(others, &(not Map.has_key?(state.owners, &1)))
    token_keys = Enum.filter(free, &Map.has_key?(retried, &1))

    # A caller that waits owns nothing, so two callers can't wait on each other. A
    # caller handed a retry owns a key, so it doesn't wait on others' probes.
    if in_flight == [] or mine != [] do
      state = claim_retries(state, token_keys, pid)
      state = %{state | owners: Enum.reduce(free, state.owners, &Map.put(&2, &1, pid))}
      state = update_proc(state, pid, &%{&1 | owned: MapSet.union(&1.owned, MapSet.new(free))})
      {:reply, {mine ++ free, []}, maybe_forget(state, pid)}
    else
      waiters =
        Enum.reduce(in_flight, state.waiters, fn key, waiters ->
          waiter = %{pid: pid, retried?: Map.has_key?(retried, key)}
          Map.update(waiters, key, %{reply_to => waiter}, &Map.put(&1, reply_to, waiter))
        end)

      state = %{state | waiters: waiters}
      state = update_proc(state, pid, &%{&1 | wait: {reply_to, MapSet.new(in_flight)}})
      {:reply, {[], in_flight}, state}
    end
  end

  @impl GenServer
  def handle_cast({:release, pid, keys, notice}, state),
    do: {:noreply, release_owned(state, pid, keys, notice)}

  # Sent when a caller stops waiting. Any key handed to it for a retry is passed on,
  # because it will not make that request.
  def handle_cast({:unwait, pid, reply_to}, state) do
    state =
      case state.procs do
        %{^pid => %{wait: {^reply_to, _keys}}} -> unwait(state, pid)
        _other -> state
      end

    owned = state.procs |> Map.get(pid, %{owned: MapSet.new()}) |> Map.fetch!(:owned)
    {:noreply, release_owned(state, pid, MapSet.to_list(owned), :abandoned)}
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
    pid = Map.fetch!(state.owners, key)
    state = %{state | owners: Map.delete(state.owners, key)}
    state = finish_retry(state, key, pid, notice)
    key_waiters = Map.get(state.waiters, key, %{})

    case notice do
      :settled ->
        notify_waiters(state, key, :settled)

      :abandoned ->
        hand_off(state, key, :abandoned)

      # Waiters that already had their group's retry proceed in parallel. Waiters
      # that arrived later get one retry of their own.
      :unresolved ->
        {retried, fresh} = Enum.split_with(key_waiters, fn {_ref, w} -> w.retried? end)
        state = %{state | waiters: put_key_waiters(state.waiters, key, Map.new(retried))}
        state = notify_waiters(state, key, :settled)

        fresh = Map.new(fresh, fn {ref, w} -> {ref, %{w | retried?: true}} end)
        state = %{state | waiters: put_key_waiters(state.waiters, key, fresh)}
        hand_off(state, key, :retry)
    end
  end

  # Hands the key to one waiting caller that waits on nothing else. The other
  # waiters stay registered and wait for that caller's request instead of
  # competing to make their own. If every waiter still waits on another key, they
  # are all told `fallback`, and reclaim this key once their other keys settle.
  defp hand_off(state, key, fallback) do
    candidate =
      state.waiters
      |> Map.get(key, %{})
      |> Enum.find(fn {_ref, %{pid: pid}} -> waited_key_count(state, pid) == 1 end)

    case candidate do
      nil when fallback == :retry and is_map_key(state.waiters, key) ->
        token = make_ref()
        expires_at = System.monotonic_time(:millisecond) + @wait_timeout_ms
        retry = %{token: token, status: :open, owner: nil, expires_at: expires_at}
        state = %{state | retries: Map.put(state.retries, key, retry)}
        notify_waiters(state, key, {:retry, token})

      nil ->
        notify_waiters(state, key, fallback)

      {reply_to, %{pid: waiter}} ->
        send(reply_to, {reply_to, :granted, key})

        %{state | waiters: remove_waiter(state.waiters, key, reply_to)}
        |> claim_open_retry(key, waiter)
        |> Map.update!(:owners, &Map.put(&1, key, waiter))
        |> drop_waited_key(waiter, key)
        |> update_proc(waiter, &%{&1 | owned: MapSet.put(&1.owned, key)})
    end
  end

  defp notify_waiters(state, key, notice) do
    Enum.reduce(Map.get(state.waiters, key, %{}), state, fn {reply_to, %{pid: waiter}}, state ->
      send(reply_to, {reply_to, notice, key})

      %{state | waiters: remove_waiter(state.waiters, key, reply_to)}
      |> drop_waited_key(waiter, key)
      |> maybe_forget(waiter)
    end)
  end

  # A free key the caller was assigned a shared retry for is led only by the
  # first caller of that group to reclaim it. Once the retry has run, the rest of
  # the group proceeds without coordinating that key again.
  # A caller holding a retry token for a key skips that key once the retry has
  # finished or been replaced, instead of joining an unrelated probe. A pruned
  # token counts as finished.
  defp finished_retry?(state, key, retried) do
    case {Map.fetch(retried, key), Map.get(state.retries, key)} do
      {:error, _retry} -> false
      {{:ok, token}, %{token: token, status: status}} -> status == :done
      {{:ok, _token}, _retry} -> true
    end
  end

  defp claim_open_retry(state, key, pid) do
    case Map.fetch(state.retries, key) do
      {:ok, %{status: :open}} -> claim_retries(state, [key], pid)
      _other -> state
    end
  end

  defp claim_retries(state, keys, pid) do
    retries =
      Enum.reduce(keys, state.retries, fn key, retries ->
        Map.update!(retries, key, &%{&1 | status: :claimed, owner: pid})
      end)

    %{state | retries: retries}
  end

  # Only the caller running a group's retry can finish or reopen it. An abandoned
  # retry reopens, so the group's next caller to reclaim the key runs it.
  defp finish_retry(state, key, pid, notice) do
    case Map.fetch(state.retries, key) do
      {:ok, %{status: :claimed, owner: ^pid} = retry} ->
        retry =
          if notice == :abandoned,
            do: %{retry | status: :open, owner: nil},
            else: %{retry | status: :done, owner: nil}

        %{state | retries: Map.put(state.retries, key, retry)}

      _other ->
        state
    end
  end

  defp prune_retries(%{retries: retries} = state) when map_size(retries) == 0, do: state

  defp prune_retries(state) do
    now = System.monotonic_time(:millisecond)
    %{state | retries: Map.reject(state.retries, fn {_key, retry} -> retry.expires_at < now end)}
  end

  defp waited_key_count(state, pid) do
    case state.procs do
      %{^pid => %{wait: {_reply_to, keys}}} -> MapSet.size(keys)
      _other -> 0
    end
  end

  defp put_key_waiters(waiters, key, key_waiters) when map_size(key_waiters) == 0,
    do: Map.delete(waiters, key)

  defp put_key_waiters(waiters, key, key_waiters), do: Map.put(waiters, key, key_waiters)

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
