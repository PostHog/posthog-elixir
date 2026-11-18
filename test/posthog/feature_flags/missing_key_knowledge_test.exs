defmodule PostHog.FeatureFlags.MissingKeyKnowledgeTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox

  alias PostHog.FeatureFlags
  alias PostHog.FeatureFlags.DefinitionLoader
  alias PostHog.FeatureFlags.Evaluations

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    stub(PostHog.API.Mock, :client, fn _api_key, _host ->
      %PostHog.API.Client{client: :stub_client, module: PostHog.API.Mock}
    end)

    :ok
  end

  defp envelope(flags \\ []) do
    %{"flags" => flags, "group_type_mapping" => %{}, "cohorts" => %{}}
  end

  defp start_instance(name, overrides \\ []) do
    config =
      [
        api_key: "token",
        secret_key: "secret",
        api_client_module: PostHog.API.Mock,
        supervisor_name: name,
        test_mode: true,
        feature_flags_poll_interval_ms: 60_000
      ]
      |> Keyword.merge(overrides)
      |> PostHog.Config.validate!()
      |> Map.put(:sender_pool_size, 1)

    start_supervised!({PostHog.Supervisor, config})
  end

  defp scoped(name, keys, distinct_id \\ "user") do
    FeatureFlags.evaluate_flags(name, %{distinct_id: distinct_id, flag_keys: keys})
  end

  defp eventually(check, attempts \\ 100) do
    cond do
      check.() ->
        :ok

      attempts == 0 ->
        flunk("condition was not met")

      true ->
        Process.sleep(10)
        eventually(check, attempts - 1)
    end
  end

  defp sync_loader(name) do
    :sys.get_state(PostHog.Registry.via(name, DefinitionLoader))
    :ok
  end

  test "clean omission is retained sequentially and successful refresh invalidates it" do
    owner = self()
    {:ok, count} = Agent.start_link(fn -> 0 end)

    expect(PostHog.API.Mock, :request, 5, fn :stub_client, method, path, _opts ->
      index = Agent.get_and_update(count, &{&1, &1 + 1})

      case {index, method, path} do
        {0, :get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {1, :post, "/flags"} ->
          send(owner, :remote_probe)
          {:ok, %{status: 200, body: %{"flags" => %{}}}}

        {2, :get, "/flags/definitions"} ->
          {:ok, %{status: 503, body: %{}, headers: %{}}}

        {3, :get, "/flags/definitions"} ->
          {:ok, %{status: 304, body: nil, headers: %{}}}

        {4, :post, "/flags"} ->
          send(owner, :remote_probe)
          {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end
    end)

    start_instance(__MODULE__.Sequential)
    assert {:ok, first} = scoped(__MODULE__.Sequential, ["missing"])
    assert Evaluations.keys(first) == []
    assert_receive :remote_probe
    sync_loader(__MODULE__.Sequential)

    assert {:ok, second} = scoped(__MODULE__.Sequential, ["missing"])
    assert Evaluations.keys(second) == []
    refute_receive :remote_probe

    capture_log(fn -> DefinitionLoader.refresh(__MODULE__.Sequential) end)
    assert {:ok, still_retained} = scoped(__MODULE__.Sequential, ["missing"])
    assert Evaluations.keys(still_retained) == []
    refute_receive :remote_probe

    DefinitionLoader.refresh(__MODULE__.Sequential)
    assert {:ok, _third} = scoped(__MODULE__.Sequential, ["missing"])
    assert_receive :remote_probe
  end

  test "remote-only and locally unresolved total failures preserve the error contract" do
    expect(PostHog.API.Mock, :request, fn :stub_client, :post, "/flags", _opts ->
      {:error, %RuntimeError{message: "offline"}}
    end)

    start_instance(__MODULE__.RemoteOnly, secret_key: nil)

    assert {:error, %RuntimeError{message: "offline"}} =
             scoped(__MODULE__.RemoteOnly, ["missing"])

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    expect(PostHog.API.Mock, :request, 3, fn :stub_client, method, path, _opts ->
      case {Agent.get_and_update(counter, &{&1, &1 + 1}), method, path} do
        {0, :get, "/flags/definitions"} -> {:ok, %{status: 200, body: envelope(), headers: %{}}}
        {_index, :post, "/flags"} -> {:error, %RuntimeError{message: "offline"}}
      end
    end)

    start_instance(__MODULE__.Failure)
    assert {:error, %RuntimeError{message: "offline"}} = scoped(__MODULE__.Failure, ["missing"])
    assert {:error, %RuntimeError{message: "offline"}} = scoped(__MODULE__.Failure, ["missing"])
  end

  test "fallback publishes negative knowledge before releasing a probe during refresh" do
    owner = self()
    {:ok, definition_calls} = Agent.start_link(fn -> 0 end)

    expect(PostHog.API.Mock, :request, 3, fn :stub_client, method, path, _opts ->
      case {method, path} do
        {:get, "/flags/definitions"} ->
          case Agent.get_and_update(definition_calls, &{&1, &1 + 1}) do
            0 ->
              {:ok, %{status: 200, body: envelope(), headers: %{}}}

            1 ->
              send(owner, {:refresh_started, self()})
              receive do: (:release_refresh -> :ok)
              {:ok, %{status: 503, body: nil, headers: %{}}}
          end

        {:post, "/flags"} ->
          {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end
    end)

    start_instance(__MODULE__.NonBlocking)
    refresh = Task.async(fn -> DefinitionLoader.refresh(__MODULE__.NonBlocking) end)
    assert_receive {:refresh_started, refresh_worker}

    fallback = Task.async(fn -> scoped(__MODULE__.NonBlocking, ["missing"]) end)
    assert {:ok, {:ok, snapshot}} = Task.yield(fallback, 500)
    assert Evaluations.keys(snapshot) == []

    assert {:ok, repeated} = scoped(__MODULE__.NonBlocking, ["missing"], "second")
    assert Evaluations.keys(repeated) == []

    send(refresh_worker, :release_refresh)
    assert :ok = Task.await(refresh)
  end

  test "dirty omissions do not suppress retries and returned keys remain context specific" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    expect(PostHog.API.Mock, :request, 5, fn :stub_client, method, path, _opts ->
      case {Agent.get_and_update(counter, &{&1, &1 + 1}), method, path} do
        {0, :get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {1, :post, "/flags"} ->
          {:ok, %{status: 200, body: %{"flags" => %{}, "errorsWhileComputingFlags" => true}}}

        {2, :post, "/flags"} ->
          {:ok, %{status: 200, body: %{"flags" => %{}, "quotaLimited" => ["feature_flags"]}}}

        {index, :post, "/flags"} when index in [3, 4] ->
          {:ok, %{status: 200, body: %{"flags" => %{"missing" => %{"enabled" => true}}}}}
      end
    end)

    start_instance(__MODULE__.Dirty)
    assert {:ok, _dirty} = scoped(__MODULE__.Dirty, ["missing"])
    assert {:ok, _quota} = scoped(__MODULE__.Dirty, ["missing"])
    assert {:ok, returned} = scoped(__MODULE__.Dirty, ["missing"], "one")
    assert returned.flags["missing"].enabled
    assert {:ok, returned_again} = scoped(__MODULE__.Dirty, ["missing"], "two")
    assert returned_again.flags["missing"].enabled
  end

  test "overlapping clean probes coalesce while a returned value makes the waiter probe itself" do
    owner = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    expect(PostHog.API.Mock, :request, 2, fn :stub_client, method, path, _opts ->
      case {method, path} do
        {:get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags"} ->
          call = Agent.get_and_update(calls, &{&1, &1 + 1})
          send(owner, {:overlap_probe, call, self()})
          receive do: (:release_overlap -> :ok)
          {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end
    end)

    start_instance(__MODULE__.Overlap)
    first = Task.async(fn -> scoped(__MODULE__.Overlap, ["missing"], "one") end)
    assert_receive {:overlap_probe, 0, worker}
    second = Task.async(fn -> scoped(__MODULE__.Overlap, ["missing"], "two") end)
    refute_receive {:overlap_probe, 1, _worker}, 50
    send(worker, :release_overlap)
    assert {:ok, _snapshot} = Task.await(first)
    assert {:ok, _snapshot} = Task.await(second)
    assert Agent.get(calls, & &1) == 1

    # A refreshed generation starts a new probe. Returning a key does not share
    # its identity-specific value with the overlapping waiter.
    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 304, body: nil, headers: %{}}}
    end)

    DefinitionLoader.refresh(__MODULE__.Overlap)

    expect(PostHog.API.Mock, :request, 2, fn :stub_client, :post, "/flags", _opts ->
      call = Agent.get_and_update(calls, &{&1, &1 + 1})
      send(owner, {:returned_probe, call, self()})
      if call == 1, do: receive(do: (:release_returned -> :ok))
      {:ok, %{status: 200, body: %{"flags" => %{"missing" => %{"enabled" => true}}}}}
    end)

    returned_first = Task.async(fn -> scoped(__MODULE__.Overlap, ["missing"], "three") end)
    assert_receive {:returned_probe, 1, returned_worker}
    returned_waiter = Task.async(fn -> scoped(__MODULE__.Overlap, ["missing"], "four") end)
    refute_receive {:returned_probe, 2, _worker}, 50
    send(returned_worker, :release_returned)
    assert_receive {:returned_probe, 2, _worker}
    assert {:ok, _snapshot} = Task.await(returned_first)
    assert {:ok, _snapshot} = Task.await(returned_waiter)
  end

  test "disjoint probes proceed concurrently and mixed overlapping sets recheck before one original-scope request" do
    owner = self()

    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 200, body: envelope(), headers: %{}}}
    end)

    expect(PostHog.API.Mock, :request, 2, fn :stub_client, :post, "/flags", opts ->
      [key] = opts[:json].flag_keys_to_evaluate
      send(owner, {:disjoint_started, key, self()})
      receive do: (:release_disjoint -> :ok)
      {:ok, %{status: 200, body: %{"flags" => %{}}}}
    end)

    start_instance(__MODULE__.Sets)
    a = Task.async(fn -> scoped(__MODULE__.Sets, ["a"]) end)
    b = Task.async(fn -> scoped(__MODULE__.Sets, ["b"]) end)
    assert_receive {:disjoint_started, "a", worker_a}
    assert_receive {:disjoint_started, "b", worker_b}
    send(worker_a, :release_disjoint)
    send(worker_b, :release_disjoint)
    Task.await(a)
    Task.await(b)

    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 304, body: nil, headers: %{}}}
    end)

    DefinitionLoader.refresh(__MODULE__.Sets)

    expect(PostHog.API.Mock, :request, 2, fn :stub_client, :post, "/flags", opts ->
      keys = opts[:json].flag_keys_to_evaluate
      send(owner, {:mixed_probe, keys, self()})
      if keys == ["a"], do: receive(do: (:release_mixed -> :ok))
      {:ok, %{status: 200, body: %{"flags" => %{}}}}
    end)

    overlap = Task.async(fn -> scoped(__MODULE__.Sets, ["a"]) end)
    assert_receive {:mixed_probe, ["a"], overlap_worker}
    mixed = Task.async(fn -> scoped(__MODULE__.Sets, ["a", "b"]) end)
    refute_receive {:mixed_probe, ["a", "b"], _worker}, 50
    send(overlap_worker, :release_mixed)
    assert_receive {:mixed_probe, ["a", "b"], _worker}
    Task.await(overlap)
    Task.await(mixed)
  end

  test "a delayed omission cannot reinstall knowledge cleared by newer positive evidence" do
    owner = self()
    {:ok, a_requests} = Agent.start_link(fn -> 0 end)

    expect(PostHog.API.Mock, :request, 5, fn :stub_client, method, path, opts ->
      case {method, path} do
        {:get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags"} ->
          case opts[:json].flag_keys_to_evaluate do
            ["a"] ->
              Agent.update(a_requests, &(&1 + 1))
              {:ok, %{status: 200, body: %{"flags" => %{}}}}

            ["a", "b"] ->
              send(owner, {:delayed_omission, self()})
              receive do: (:release_delayed_omission -> :ok)
              {:ok, %{status: 200, body: %{"flags" => %{}}}}

            ["a", "c"] ->
              {:ok, %{status: 200, body: %{"flags" => %{"a" => %{"enabled" => true}}}}}
          end
      end
    end)

    start_instance(__MODULE__.Ordering)

    assert {:ok, _snapshot} = scoped(__MODULE__.Ordering, ["a"])
    sync_loader(__MODULE__.Ordering)

    assert MapSet.member?(
             DefinitionLoader.evaluation_state(__MODULE__.Ordering, ["a"]).known_missing,
             "a"
           )

    delayed = Task.async(fn -> scoped(__MODULE__.Ordering, ["a", "b"], "delayed") end)
    assert_receive {:delayed_omission, delayed_worker}

    assert {:ok, positive} = scoped(__MODULE__.Ordering, ["a", "c"], "positive")
    assert positive.flags["a"].enabled
    sync_loader(__MODULE__.Ordering)

    send(delayed_worker, :release_delayed_omission)
    assert {:ok, _snapshot} = Task.await(delayed)
    sync_loader(__MODULE__.Ordering)

    refute MapSet.member?(
             DefinitionLoader.evaluation_state(__MODULE__.Ordering, ["a"]).known_missing,
             "a"
           )

    assert {:ok, _snapshot} = scoped(__MODULE__.Ordering, ["a"], "after")
    assert Agent.get(a_requests, & &1) == 2
  end

  test "loader restarts use a new generation incarnation" do
    expect(PostHog.API.Mock, :request, 2, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 200, body: envelope(), headers: %{}}}
    end)

    start_instance(__MODULE__.Restart)
    old_generation = DefinitionLoader.evaluation_state(__MODULE__.Restart, []).generation
    assert :ok = stop_supervised(__MODULE__.Restart)

    start_instance(__MODULE__.Restart)
    new_generation = DefinitionLoader.evaluation_state(__MODULE__.Restart, []).generation

    refute new_generation == old_generation

    assert :ok =
             DefinitionLoader.update_negative_knowledge(
               __MODULE__.Restart,
               old_generation,
               ["missing"],
               [],
               true
             )

    sync_loader(__MODULE__.Restart)

    assert MapSet.new() ==
             DefinitionLoader.evaluation_state(__MODULE__.Restart, ["missing"]).known_missing
  end

  test "oversized missing-key scopes preserve the remote scope without retaining omissions" do
    owner = self()
    keys = for index <- 0..1_000, do: "key-#{index}"

    expect(PostHog.API.Mock, :request, 3, fn :stub_client, method, path, opts ->
      case {method, path} do
        {:get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags"} ->
          send(owner, {:oversized_scope, opts[:json].flag_keys_to_evaluate})
          {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end
    end)

    start_instance(__MODULE__.Oversized)

    assert {:ok, first} = scoped(__MODULE__.Oversized, keys)
    assert Evaluations.keys(first) == []
    assert_receive {:oversized_scope, ^keys}

    assert DefinitionLoader.evaluation_state(__MODULE__.Oversized, keys).known_missing ==
             MapSet.new()

    assert {:ok, second} = scoped(__MODULE__.Oversized, keys)
    assert Evaluations.keys(second) == []
    assert_receive {:oversized_scope, ^keys}
  end

  test "negative knowledge is bounded, returned keys are removed, and stale generations are discarded" do
    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 200, body: envelope(), headers: %{}}}
    end)

    start_instance(__MODULE__.Capacity)
    initial = DefinitionLoader.evaluation_state(__MODULE__.Capacity, [])
    keys = for index <- 0..1_000, do: "key-#{String.pad_leading(to_string(index), 4, "0")}"

    assert :ok =
             DefinitionLoader.update_negative_knowledge(
               __MODULE__.Capacity,
               initial.generation,
               keys,
               [],
               true
             )

    sync_loader(__MODULE__.Capacity)
    retained = DefinitionLoader.evaluation_state(__MODULE__.Capacity, keys).known_missing
    assert MapSet.size(retained) == 1_000
    refute MapSet.member?(retained, hd(keys))
    assert MapSet.member?(retained, List.last(keys))

    returned = List.last(keys)

    assert :ok =
             DefinitionLoader.update_negative_knowledge(
               __MODULE__.Capacity,
               initial.generation,
               [],
               [returned],
               false
             )

    sync_loader(__MODULE__.Capacity)

    refute MapSet.member?(
             DefinitionLoader.evaluation_state(__MODULE__.Capacity, [returned]).known_missing,
             returned
           )

    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 304, body: nil, headers: %{}}}
    end)

    DefinitionLoader.refresh(__MODULE__.Capacity)

    assert :ok =
             DefinitionLoader.update_negative_knowledge(
               __MODULE__.Capacity,
               initial.generation,
               ["race"],
               [],
               true
             )

    sync_loader(__MODULE__.Capacity)

    assert MapSet.size(DefinitionLoader.evaluation_state(__MODULE__.Capacity, keys).known_missing) ==
             0
  end

  test "a stalled probe bounds how long overlapping evaluations wait" do
    owner = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    expect(PostHog.API.Mock, :request, 3, fn :stub_client, method, path, _opts ->
      case {method, path} do
        {:get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags"} ->
          call = Agent.get_and_update(calls, &{&1, &1 + 1})
          send(owner, {:stalled_probe, call, self()})
          if call == 0, do: receive(do: (:release_stalled -> :ok))
          {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end
    end)

    start_instance(__MODULE__.Stalled)
    stalled = Task.async(fn -> scoped(__MODULE__.Stalled, ["missing"], "one") end)
    assert_receive {:stalled_probe, 0, worker}

    waiter = Task.async(fn -> scoped(__MODULE__.Stalled, ["missing"], "two") end)
    refute_receive {:stalled_probe, 1, _worker}, 1_000
    assert_receive {:stalled_probe, 1, _worker}, 2_000
    assert {:ok, _snapshot} = Task.await(waiter)

    coordinator = PostHog.Registry.via(__MODULE__.Stalled, FeatureFlags.MissingProbeCoordinator)
    assert :sys.get_state(coordinator).waiters == %{}

    send(worker, :release_stalled)
    assert {:ok, _snapshot} = Task.await(stalled)
  end

  test "a crashed probe owner hands the probe to one waiter" do
    owner = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    expect(PostHog.API.Mock, :request, 3, fn :stub_client, method, path, _opts ->
      case {method, path} do
        {:get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags"} ->
          call = Agent.get_and_update(calls, &{&1, &1 + 1})
          send(owner, {:crash_probe, call, self()})
          if call == 0, do: receive(do: (:never -> :ok))
          {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end
    end)

    start_instance(__MODULE__.Crashed)

    {:ok, crashed} =
      Task.start(fn -> scoped(__MODULE__.Crashed, ["missing"], "one") end)

    assert_receive {:crash_probe, 0, _worker}

    waiters =
      for id <- ["two", "three", "four"],
          do: Task.async(fn -> scoped(__MODULE__.Crashed, ["missing"], id) end)

    refute_receive {:crash_probe, 1, _worker}, 50
    Process.exit(crashed, :kill)
    assert_receive {:crash_probe, 1, _worker}, 500
    Enum.each(waiters, &assert({:ok, _snapshot} = Task.await(&1)))
    refute_receive {:crash_probe, 2, _worker}, 50
  end

  test "killed waiters are removed from a stalled probe" do
    owner = self()

    expect(PostHog.API.Mock, :request, 2, fn :stub_client, method, path, _opts ->
      case {method, path} do
        {:get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags"} ->
          send(owner, {:killed_waiter_probe, self()})
          receive do: (:release_killed_waiter -> :ok)
          {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end
    end)

    start_instance(__MODULE__.KilledWaiter)
    stalled = Task.async(fn -> scoped(__MODULE__.KilledWaiter, ["missing"], "one") end)
    assert_receive {:killed_waiter_probe, worker}

    coordinator =
      PostHog.Registry.via(__MODULE__.KilledWaiter, FeatureFlags.MissingProbeCoordinator)

    {:ok, waiter} = Task.start(fn -> scoped(__MODULE__.KilledWaiter, ["missing"], "two") end)
    eventually(fn -> map_size(:sys.get_state(coordinator).waiters) == 1 end)

    Process.exit(waiter, :kill)

    eventually(fn ->
      state = :sys.get_state(coordinator)
      state.waiters == %{} and not Map.has_key?(state.procs, waiter)
    end)

    send(worker, :release_killed_waiter)
    assert {:ok, _snapshot} = Task.await(stalled)
    assert :sys.get_state(coordinator).procs == %{}
  end

  test "a probe that raises hands the probe to one waiter" do
    owner = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    expect(PostHog.API.Mock, :request, 3, fn :stub_client, method, path, _opts ->
      case {method, path} do
        {:get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags"} ->
          call = Agent.get_and_update(calls, &{&1, &1 + 1})
          send(owner, {:raising_probe, call, self()})

          if call == 0 do
            receive do: (:raise_probe -> :ok)
            raise "probe failed"
          end

          {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end
    end)

    start_instance(__MODULE__.Raising)

    raising =
      Task.async(fn ->
        try do
          scoped(__MODULE__.Raising, ["missing"], "one")
        rescue
          error -> error
        end
      end)

    assert_receive {:raising_probe, 0, worker}

    waiters =
      for id <- ["two", "three", "four"],
          do: Task.async(fn -> scoped(__MODULE__.Raising, ["missing"], id) end)

    refute_receive {:raising_probe, 1, _worker}, 50
    send(worker, :raise_probe)
    assert %RuntimeError{message: "probe failed"} = Task.await(raising)
    assert_receive {:raising_probe, 1, _worker}, 500
    Enum.each(waiters, &assert({:ok, _snapshot} = Task.await(&1)))
    refute_receive {:raising_probe, 2, _worker}, 50
  end

  test "returned-key history overflow only distrusts probes that overlapped it" do
    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 200, body: envelope(), headers: %{}}}
    end)

    name = __MODULE__.ReturnedHistory
    start_instance(name)
    %{generation: generation} = DefinitionLoader.evaluation_state(name, [])
    returned = for index <- 0..1_000, do: "returned-#{index}"

    update = fn requested, returned, started ->
      :ok =
        DefinitionLoader.update_negative_knowledge(
          name,
          generation,
          requested,
          returned,
          true,
          started
        )

      DefinitionLoader.evaluation_state(name, requested).known_missing
    end

    overlapping = DefinitionLoader.probe_started(name)

    assert update.(["missing" | returned], returned, DefinitionLoader.probe_started(name)) ==
             MapSet.new(["missing"])

    assert update.(["overlapping-missing"], [], overlapping) == MapSet.new()

    assert update.(["later-missing"], [], DefinitionLoader.probe_started(name)) ==
             MapSet.new(["later-missing"])
  end

  test "an omission from before a negative-knowledge restart is not retained" do
    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 200, body: envelope(), headers: %{}}}
    end)

    name = __MODULE__.KnowledgeRestart
    start_instance(name)
    %{generation: generation} = DefinitionLoader.evaluation_state(name, [])
    knowledge = PostHog.Registry.via(name, DefinitionLoader.NegativeKnowledge)

    update = fn requested, returned, started ->
      :ok =
        DefinitionLoader.update_negative_knowledge(
          name,
          generation,
          requested,
          returned,
          true,
          started
        )
    end

    Enum.each(1..5, fn _ -> update.([], ["other"], DefinitionLoader.probe_started(name)) end)
    older = DefinitionLoader.probe_started(name)

    old_pid = GenServer.whereis(knowledge)
    Process.exit(old_pid, :kill)
    eventually(fn -> GenServer.whereis(knowledge) not in [nil, old_pid] end)

    update.([], ["new"], DefinitionLoader.probe_started(name))
    update.(["new"], [], older)

    refute MapSet.member?(DefinitionLoader.evaluation_state(name, ["new"]).known_missing, "new")
  end

  test "an older probe's omission cannot hide a key a newer probe returned" do
    owner = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    expect(PostHog.API.Mock, :request, 3, fn :stub_client, method, path, _opts ->
      case {method, path} do
        {:get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags"} ->
          case Agent.get_and_update(calls, &{&1, &1 + 1}) do
            0 ->
              send(owner, {:older_probe, self()})
              receive do: (:release_older -> :ok)
              {:ok, %{status: 200, body: %{"flags" => %{}}}}

            1 ->
              {:ok, %{status: 200, body: %{"flags" => %{"new" => %{"enabled" => true}}}}}
          end
      end
    end)

    start_instance(__MODULE__.Superseded)
    older = Task.async(fn -> scoped(__MODULE__.Superseded, ["new"], "one") end)
    assert_receive {:older_probe, older_worker}

    # The waiter gives up after its bounded wait and makes the newer probe.
    assert {:ok, newer} = scoped(__MODULE__.Superseded, ["new"], "two")
    assert newer.flags["new"].enabled

    send(older_worker, :release_older)
    assert {:ok, _snapshot} = Task.await(older)
    sync_loader(__MODULE__.Superseded)

    refute MapSet.member?(
             DefinitionLoader.evaluation_state(__MODULE__.Superseded, ["new"]).known_missing,
             "new"
           )
  end

  test "an errored probe gets one shared retry, then its waiters proceed in parallel" do
    owner = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    expect(PostHog.API.Mock, :request, 6, fn :stub_client, method, path, _opts ->
      case {method, path} do
        {:get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags"} ->
          call = Agent.get_and_update(calls, &{&1, &1 + 1})
          send(owner, {:errored_probe, call, self()})
          receive do: (:release_errored -> :ok)
          {:ok, %{status: 200, body: %{"flags" => %{}, "errorsWhileComputingFlags" => true}}}
      end
    end)

    name = __MODULE__.Errored
    start_instance(name)
    coordinator = PostHog.Registry.via(name, FeatureFlags.MissingProbeCoordinator)
    first = Task.async(fn -> scoped(name, ["missing"], "one") end)
    assert_receive {:errored_probe, 0, first_worker}

    waiters =
      for id <- ["two", "three", "four", "five"],
          do: Task.async(fn -> scoped(name, ["missing"], id) end)

    eventually(fn -> waiter_count(coordinator, "missing") == 4 end)

    send(first_worker, :release_errored)
    assert {:ok, _snapshot} = Task.await(first)
    assert_receive {:errored_probe, 1, retry_worker}
    refute_receive {:errored_probe, 2, _worker}, 50

    send(retry_worker, :release_errored)

    workers =
      for call <- 2..4 do
        assert_receive {:errored_probe, ^call, worker}
        worker
      end

    Enum.each(workers, &send(&1, :release_errored))
    Enum.each(waiters, &assert({:ok, _snapshot} = Task.await(&1)))
  end

  test "a caller that starts waiting during a shared retry shares that retry's result" do
    alias FeatureFlags.MissingProbeCoordinator, as: Coordinator

    name = __MODULE__.LateWaiter
    start_coordinator_only(name)
    coordinator = PostHog.Registry.via(name, Coordinator)
    owner = self()

    first = coordinated_probe(name, :first, owner)
    assert_receive {:probe, :first, ["missing"], first_worker}
    early = coordinated_probe(name, :early, owner)
    eventually(fn -> waiter_count(coordinator, "missing") == 1 end)

    send(first_worker, {:finish, ["missing"]})
    assert :ok = Task.await(first)
    assert_receive {:probe, :early, ["missing"], retry_worker}

    late = coordinated_probe(name, :late, owner)
    eventually(fn -> waiter_count(coordinator, "missing") == 1 end)

    send(retry_worker, {:finish, []})
    assert :ok = Task.await(early)
    assert_receive {:probe, :late, [], late_worker}
    send(late_worker, {:finish, []})
    assert :ok = Task.await(late)
  end

  test "a caller that arrives after a failed shared retry starts fresh coordination" do
    alias FeatureFlags.MissingProbeCoordinator, as: Coordinator

    name = __MODULE__.FreshAfterRetry
    start_coordinator_only(name)
    coordinator = PostHog.Registry.via(name, Coordinator)
    owner = self()

    first = coordinated_probe(name, :first, owner)
    assert_receive {:probe, :first, ["missing"], first_worker}
    early = coordinated_probe(name, :early, owner)
    eventually(fn -> waiter_count(coordinator, "missing") == 1 end)

    send(first_worker, {:finish, ["missing"]})
    assert :ok = Task.await(first)
    assert_receive {:probe, :early, ["missing"], retry_worker}
    send(retry_worker, {:finish, ["missing"]})
    assert :ok = Task.await(early)

    new_owner = coordinated_probe(name, :new_owner, owner)
    assert_receive {:probe, :new_owner, ["missing"], new_worker}
    new_waiter = coordinated_probe(name, :new_waiter, owner)
    eventually(fn -> waiter_count(coordinator, "missing") == 1 end)

    send(new_worker, {:finish, []})
    assert :ok = Task.await(new_owner)
    assert_receive {:probe, :new_waiter, [], waiter_worker}
    send(waiter_worker, {:finish, []})
    assert :ok = Task.await(new_waiter)
  end

  test "a shared retry that fails before the other waiters resume starts no second retry" do
    alias FeatureFlags.MissingProbeCoordinator, as: Coordinator

    name = __MODULE__.FastRetry
    start_coordinator_only(name)
    coordinator = PostHog.Registry.via(name, Coordinator)
    owner = self()

    first = coordinated_probe(name, :first, owner)
    assert_receive {:probe, :first, ["missing"], first_worker}
    waiters = for id <- [:a, :b, :c], do: coordinated_probe(name, id, owner)
    eventually(fn -> waiter_count(coordinator, "missing") == 3 end)

    send(first_worker, {:finish, ["missing"]})
    assert :ok = Task.await(first)
    assert_receive {:probe, retry_id, ["missing"], retry_worker}

    held = Enum.reject(waiters, &(&1.pid == retry_worker))
    Enum.each(held, &:erlang.suspend_process(&1.pid))
    send(retry_worker, {:finish, ["missing"]})
    eventually(fn -> waiter_count(coordinator, "missing") == 0 end)
    Enum.each(held, &:erlang.resume_process(&1.pid))

    for id <- [:a, :b, :c] -- [retry_id] do
      assert_receive {:probe, ^id, [], worker}
      send(worker, {:finish, []})
    end

    Enum.each(waiters, &assert(:ok = Task.await(&1)))
  end

  test "a caller handed the retry that stops waiting passes it on" do
    alias FeatureFlags.MissingProbeCoordinator, as: Coordinator

    name = __MODULE__.HandoffKilled
    start_coordinator_only(name)
    coordinator = PostHog.Registry.via(name, Coordinator)
    owner = self()

    first = coordinated_probe(name, :first, owner)
    assert_receive {:probe, :first, ["missing"], first_worker}

    for id <- [:a, :b] do
      Task.start(fn ->
        FeatureFlags.MissingProbeCoordinator.run(name, ["missing"], fn owned ->
          send(owner, {:probe, id, owned, self()})
          receive do: ({:finish, unresolved} -> {:ok, unresolved})
        end)
      end)
    end

    eventually(fn -> waiter_count(coordinator, "missing") == 2 end)

    send(first_worker, {:finish, ["missing"]})
    assert :ok = Task.await(first)
    assert_receive {:probe, retry_id, ["missing"], retry_worker}
    Process.exit(retry_worker, :kill)

    [other] = [:a, :b] -- [retry_id]
    assert_receive {:probe, ^other, ["missing"], other_worker}
    send(other_worker, {:finish, []})
    eventually(fn -> :sys.get_state(coordinator).owners == %{} end)
  end

  test "a retry granted after the caller's deadline is passed on" do
    alias FeatureFlags.MissingProbeCoordinator, as: Coordinator

    name = __MODULE__.LateGrant
    start_coordinator_only(name)
    coordinator = PostHog.Registry.via(name, Coordinator)
    owner = self()

    first = coordinated_probe(name, :first, owner)
    assert_receive {:probe, :first, ["missing"], first_worker}
    late = coordinated_probe(name, :late, owner)
    eventually(fn -> waiter_count(coordinator, "missing") == 1 end)

    # The waiter is suspended past its deadline while the retry is handed to it.
    :erlang.suspend_process(late.pid)
    send(first_worker, {:finish, ["missing"]})
    assert :ok = Task.await(first)
    eventually(fn -> Map.get(:sys.get_state(coordinator).owners, "missing") == late.pid end)
    Process.sleep(2_100)
    :erlang.resume_process(late.pid)

    assert_receive {:probe, :late, [], late_worker}, 1_000
    eventually(fn -> :sys.get_state(coordinator).owners == %{} end)
    send(late_worker, {:finish, []})
    assert :ok = Task.await(late)
  end

  test "an unresolved key still gets one shared retry when its waiters wait on another key" do
    alias FeatureFlags.MissingProbeCoordinator, as: Coordinator

    name = __MODULE__.OverlapRetry
    start_coordinator_only(name)
    coordinator = PostHog.Registry.via(name, Coordinator)
    owner = self()

    probe = fn id, keys ->
      Task.async(fn ->
        Coordinator.run(name, keys, fn owned ->
          send(owner, {:probe, id, owned, self()})
          receive do: ({:finish, unresolved} -> {:ok, unresolved})
        end)
      end)
    end

    a_owner = probe.(:a_owner, ["a"])
    assert_receive {:probe, :a_owner, ["a"], a_worker}
    b_owner = probe.(:b_owner, ["b"])
    assert_receive {:probe, :b_owner, ["b"], b_worker}

    waiters = for id <- [:w1, :w2, :w3], do: probe.(id, ["a", "b"])

    eventually(fn ->
      waiter_count(coordinator, "a") == 3 and waiter_count(coordinator, "b") == 3
    end)

    # One waiter is held until the shared retry for "a" has finished.
    [held | running] = waiters
    :erlang.suspend_process(held.pid)

    send(a_worker, {:finish, ["a"]})
    assert :ok = Task.await(a_owner)
    send(b_worker, {:finish, []})
    assert :ok = Task.await(b_owner)

    assert_receive {:probe, retry_id, ["a"], retry_worker}
    refute_receive {:probe, _id, _owned, _worker}, 50
    send(retry_worker, {:finish, ["a"]})

    for id <- [:w2, :w3] -- [retry_id] do
      assert_receive {:probe, ^id, [], worker}
      send(worker, {:finish, []})
    end

    Enum.each(running, &assert(:ok = Task.await(&1)))
    :erlang.resume_process(held.pid)
    assert_receive {:probe, :w1, [], held_worker}
    send(held_worker, {:finish, []})
    assert :ok = Task.await(held)
  end

  test "a retry token is not used up by a caller that goes back to waiting" do
    alias FeatureFlags.MissingProbeCoordinator, as: Coordinator

    name = __MODULE__.TokenWait
    start_coordinator_only(name)
    coordinator = PostHog.Registry.via(name, Coordinator)
    owner = self()

    probe = fn id, keys ->
      Task.async(fn ->
        Coordinator.run(name, keys, fn owned ->
          send(owner, {:probe, id, owned, self()})
          receive do: ({:finish, unresolved} -> {:ok, unresolved})
        end)
      end)
    end

    a_owner = probe.(:a_owner, ["a"])
    assert_receive {:probe, :a_owner, ["a"], a_worker}
    b_owner = probe.(:b_owner, ["b"])
    assert_receive {:probe, :b_owner, ["b"], b_worker}
    waiters = for id <- [:w1, :w2], do: probe.(id, ["a", "b", "c"])
    eventually(fn -> waiter_count(coordinator, "a") == 2 end)

    # "a" fails while both waiters still wait on "b", so they get a retry token.
    send(a_worker, {:finish, ["a"]})
    assert :ok = Task.await(a_owner)
    eventually(fn -> waiter_count(coordinator, "a") == 0 end)

    # "c" gets an owner before "b" settles, so the waiters go back to waiting.
    c_owner = probe.(:c_owner, ["c"])
    assert_receive {:probe, :c_owner, ["c"], c_worker}
    send(b_worker, {:finish, []})
    assert :ok = Task.await(b_owner)
    eventually(fn -> waiter_count(coordinator, "c") == 2 end)

    send(c_worker, {:finish, []})
    assert :ok = Task.await(c_owner)

    assert_receive {:probe, retry_id, retry_owned, retry_worker}
    assert "a" in retry_owned
    send(retry_worker, {:finish, retry_owned})

    [other] = [:w1, :w2] -- [retry_id]
    assert_receive {:probe, ^other, other_owned, other_worker}
    refute "a" in other_owned
    send(other_worker, {:finish, []})
    Enum.each(waiters, &assert(:ok = Task.await(&1)))
  end

  test "an abandoned retry token reopens for the rest of its group" do
    alias FeatureFlags.MissingProbeCoordinator, as: Coordinator

    name = __MODULE__.TokenAbandoned
    start_coordinator_only(name)
    coordinator = PostHog.Registry.via(name, Coordinator)
    owner = self()

    {:ok, _a_owner} = start_unlinked_probe(name, owner, :a_owner, ["a"])
    assert_receive {:probe, :a_owner, ["a"], a_worker}
    {:ok, _b_owner} = start_unlinked_probe(name, owner, :b_owner, ["b"])
    assert_receive {:probe, :b_owner, ["b"], b_worker}
    {:ok, w1} = start_unlinked_probe(name, owner, :w1, ["a", "b"])
    {:ok, w2} = start_unlinked_probe(name, owner, :w2, ["a", "b"])
    eventually(fn -> waiter_count(coordinator, "a") == 2 end)

    send(a_worker, {:finish, ["a"]})
    eventually(fn -> waiter_count(coordinator, "a") == 0 end)

    # One waiter claims the retry and dies before the other resumes.
    :erlang.suspend_process(w2)
    send(b_worker, {:finish, []})
    assert_receive {:probe, :w1, ["a"], _w1_worker}
    Process.exit(w1, :kill)
    eventually(fn -> :sys.get_state(coordinator).owners == %{} end)
    :erlang.resume_process(w2)

    assert_receive {:probe, :w2, ["a"], w2_worker}
    send(w2_worker, {:finish, []})
  end

  test "an abandoned retry stays open while its group waits on another key" do
    alias FeatureFlags.MissingProbeCoordinator, as: Coordinator

    name = __MODULE__.AbandonedOverlap
    start_coordinator_only(name)
    coordinator = PostHog.Registry.via(name, Coordinator)
    owner = self()

    for {id, key} <- [a_owner: "a", c_owner: "c", d_owner: "d"] do
      {:ok, _pid} = start_unlinked_probe(name, owner, id, [key])
      assert_receive {:probe, ^id, [^key], _worker}
    end

    [a_worker, c_worker, d_worker] =
      for key <- ["a", "c", "d"], do: Map.fetch!(:sys.get_state(coordinator).owners, key)

    {:ok, w1} = start_unlinked_probe(name, owner, :w1, ["a", "c"])
    {:ok, _w2} = start_unlinked_probe(name, owner, :w2, ["a", "c", "d"])
    eventually(fn -> waiter_count(coordinator, "a") == 2 end)

    send(a_worker, {:finish, ["a"]})
    eventually(fn -> waiter_count(coordinator, "a") == 0 end)
    send(c_worker, {:finish, []})
    assert_receive {:probe, :w1, ["a"], _w1_worker}

    # A fresh caller also waits on "a" while w1 runs the group's retry.
    {:ok, _w3} = start_unlinked_probe(name, owner, :w3, ["a", "d"])
    eventually(fn -> waiter_count(coordinator, "a") == 1 end)

    Process.exit(w1, :kill)
    eventually(fn -> waiter_count(coordinator, "a") == 0 end)
    send(d_worker, {:finish, []})

    # One caller runs the reopened retry and the other waits for it.
    assert_receive {:probe, id, ["a"], worker}
    assert id in [:w2, :w3]
    refute_receive {:probe, _id, _owned, _worker}, 100
    send(worker, {:finish, []})
    assert_receive {:probe, other, [], other_worker}
    assert other in ([:w2, :w3] -- [id])
    send(other_worker, {:finish, []})
  end

  test "a finished group retry is skipped instead of joining an unrelated probe" do
    {_coordinator, w2, later_worker} = finished_group_retry(__MODULE__.FinishedSkip)

    send(w2.c_worker, {:finish, []})
    assert_receive {:probe, :w2, [], w2_worker}, 500
    send(w2_worker, {:finish, []})
    send(later_worker, {:finish, []})
  end

  test "an unrelated owner leaving does not reopen a finished group retry" do
    {coordinator, w2, _later_worker} = finished_group_retry(__MODULE__.FinishedReopen)

    Process.exit(w2.later, :kill)
    eventually(fn -> not Map.has_key?(:sys.get_state(coordinator).owners, "a") end)
    send(w2.c_worker, {:finish, []})
    assert_receive {:probe, :w2, [], w2_worker}, 500
    send(w2_worker, {:finish, []})
  end

  # Waiters w1 and w2 share a retry token for "a". w1 runs and finishes the retry
  # while w2 is suspended, then an unrelated caller claims "a" before w2 resumes.
  defp finished_group_retry(name) do
    alias FeatureFlags.MissingProbeCoordinator, as: Coordinator

    start_coordinator_only(name)
    coordinator = PostHog.Registry.via(name, Coordinator)
    owner = self()

    workers =
      for {id, key} <- [a_owner: "a", b_owner: "b", c_owner: "c"], into: %{} do
        {:ok, _pid} = start_unlinked_probe(name, owner, id, [key])
        assert_receive {:probe, ^id, [^key], worker}
        {key, worker}
      end

    {:ok, _w1} = start_unlinked_probe(name, owner, :w1, ["a", "b"])
    {:ok, w2} = start_unlinked_probe(name, owner, :w2, ["a", "c"])
    eventually(fn -> waiter_count(coordinator, "a") == 2 end)

    send(workers["a"], {:finish, ["a"]})
    eventually(fn -> waiter_count(coordinator, "a") == 0 end)

    :erlang.suspend_process(w2)
    send(workers["b"], {:finish, []})
    assert_receive {:probe, :w1, ["a"], w1_worker}
    send(w1_worker, {:finish, []})
    eventually(fn -> not Map.has_key?(:sys.get_state(coordinator).owners, "a") end)

    {:ok, later} = start_unlinked_probe(name, owner, :later, ["a"])
    assert_receive {:probe, :later, ["a"], later_worker}
    :erlang.resume_process(w2)

    {coordinator, %{later: later, c_worker: workers["c"]}, later_worker}
  end

  test "a lost retry owner leaves its overlapping group one shared retry" do
    alias FeatureFlags.MissingProbeCoordinator, as: Coordinator

    name = __MODULE__.LostRetryOwner
    start_coordinator_only(name)
    coordinator = PostHog.Registry.via(name, Coordinator)
    owner = self()

    {:ok, _} = start_unlinked_probe(name, owner, :a_owner, ["a"])
    assert_receive {:probe, :a_owner, ["a"], a_worker}
    {:ok, _} = start_unlinked_probe(name, owner, :b_owner, ["b"])
    assert_receive {:probe, :b_owner, ["b"], b_worker}

    {:ok, retrier} = start_unlinked_probe(name, owner, :retrier, ["a"])
    eventually(fn -> waiter_count(coordinator, "a") == 1 end)
    for id <- [:w2, :w3], do: {:ok, _} = start_unlinked_probe(name, owner, id, ["a", "b"])
    eventually(fn -> waiter_count(coordinator, "a") == 3 end)

    send(a_worker, {:finish, ["a"]})
    assert_receive {:probe, :retrier, ["a"], _retry_worker}
    Process.exit(retrier, :kill)
    eventually(fn -> waiter_count(coordinator, "a") == 0 end)
    send(b_worker, {:finish, []})

    assert_receive {:probe, id, ["a"], worker}
    send(worker, {:finish, ["a"]})
    [other] = [:w2, :w3] -- [id]
    assert_receive {:probe, ^other, [], other_worker}
    send(other_worker, {:finish, []})
  end

  test "a caller that takes over a key runs its open group retry" do
    alias FeatureFlags.MissingProbeCoordinator, as: Coordinator

    name = __MODULE__.TakeOverRetry
    start_coordinator_only(name)
    coordinator = PostHog.Registry.via(name, Coordinator)
    owner = self()

    {:ok, _} = start_unlinked_probe(name, owner, :a_owner, ["a"])
    assert_receive {:probe, :a_owner, ["a"], a_worker}
    {:ok, _} = start_unlinked_probe(name, owner, :b_owner, ["b"])
    assert_receive {:probe, :b_owner, ["b"], b_worker}
    {:ok, _w1} = start_unlinked_probe(name, owner, :w1, ["a", "b"])
    {:ok, w2} = start_unlinked_probe(name, owner, :w2, ["a", "b"])
    eventually(fn -> waiter_count(coordinator, "a") == 2 end)

    send(a_worker, {:finish, ["a"]})
    eventually(fn -> waiter_count(coordinator, "a") == 0 end)

    {:ok, _} = start_unlinked_probe(name, owner, :fresh, ["a"])
    assert_receive {:probe, :fresh, ["a"], fresh_worker}

    :erlang.suspend_process(w2)
    send(b_worker, {:finish, []})
    eventually(fn -> waiter_count(coordinator, "a") == 1 end)
    send(fresh_worker, {:finish, ["a"]})
    assert_receive {:probe, :w1, [], w1_worker}
    send(w1_worker, {:finish, []})

    :erlang.resume_process(w2)
    assert_receive {:probe, :w2, [], w2_worker}
    send(w2_worker, {:finish, []})
  end

  test "remote evaluation outside a coordinated probe leaves no process state" do
    expect(PostHog.API.Mock, :request, 2, fn :stub_client, method, path, _opts ->
      case {method, path} do
        {:get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags"} ->
          {:ok, %{status: 200, body: %{"flags" => %{"remote" => %{"enabled" => true}}}}}
      end
    end)

    name = __MODULE__.NoProcessState
    start_instance(name)
    assert {:ok, _snapshot} = FeatureFlags.evaluate_flags(name, %{distinct_id: "one"})
    assert Process.get({FeatureFlags, :probe_returned}) == nil
  end

  defp waiter_count(coordinator, key),
    do: map_size(Map.get(:sys.get_state(coordinator).waiters, key, %{}))

  defp start_coordinator_only(name) do
    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 200, body: envelope(), headers: %{}}}
    end)

    start_instance(name)
  end

  defp start_unlinked_probe(name, owner, id, keys) do
    Task.start(fn ->
      FeatureFlags.MissingProbeCoordinator.run(name, keys, fn owned ->
        send(owner, {:probe, id, owned, self()})
        receive do: ({:finish, unresolved} -> {:ok, unresolved})
      end)
    end)
  end

  defp coordinated_probe(name, id, owner) do
    Task.async(fn ->
      FeatureFlags.MissingProbeCoordinator.run(name, ["missing"], fn owned ->
        send(owner, {:probe, id, owned, self()})
        receive do: ({:finish, unresolved} -> {:ok, unresolved})
      end)
    end)
  end

  test "waiters on a settled probe still share one probe for their other missing key" do
    owner = self()

    expect(PostHog.API.Mock, :request, 3, fn :stub_client, method, path, opts ->
      case {method, path} do
        {:get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags"} ->
          keys = opts[:json].flag_keys_to_evaluate
          send(owner, {:shared_probe, keys, self()})
          receive do: (:release_shared -> :ok)
          {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end
    end)

    start_instance(__MODULE__.Reclaim)
    first = Task.async(fn -> scoped(__MODULE__.Reclaim, ["a"], "one") end)
    assert_receive {:shared_probe, ["a"], first_worker}

    waiters =
      for id <- ["two", "three"],
          do: Task.async(fn -> scoped(__MODULE__.Reclaim, ["a", "b"], id) end)

    refute_receive {:shared_probe, _keys, _worker}, 50
    send(first_worker, :release_shared)
    assert {:ok, _snapshot} = Task.await(first)

    assert_receive {:shared_probe, ["a", "b"], second_worker}
    refute_receive {:shared_probe, _keys, _worker}, 100
    send(second_worker, :release_shared)
    Enum.each(waiters, &assert({:ok, _snapshot} = Task.await(&1)))
  end

  test "waiters whose probe returned the key make their own requests in parallel" do
    owner = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    expect(PostHog.API.Mock, :request, 4, fn :stub_client, method, path, _opts ->
      case {method, path} do
        {:get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags"} ->
          call = Agent.get_and_update(calls, &{&1, &1 + 1})
          send(owner, {:parallel_probe, call, self()})
          receive do: (:release_parallel -> :ok)
          {:ok, %{status: 200, body: %{"flags" => %{"remote" => %{"enabled" => true}}}}}
      end
    end)

    start_instance(__MODULE__.Parallel)
    first = Task.async(fn -> scoped(__MODULE__.Parallel, ["remote"], "one") end)
    assert_receive {:parallel_probe, 0, first_worker}

    waiters =
      for id <- ["two", "three"],
          do: Task.async(fn -> scoped(__MODULE__.Parallel, ["remote"], id) end)

    coordinator = PostHog.Registry.via(__MODULE__.Parallel, FeatureFlags.MissingProbeCoordinator)

    eventually(fn ->
      map_size(Map.get(:sys.get_state(coordinator).waiters, "remote", %{})) == 2
    end)

    refute_receive {:parallel_probe, _call, _worker}, 50
    send(first_worker, :release_parallel)
    assert {:ok, _snapshot} = Task.await(first)

    assert_receive {:parallel_probe, 1, worker_one}
    assert_receive {:parallel_probe, 2, worker_two}
    send(worker_one, :release_parallel)
    send(worker_two, :release_parallel)
    Enum.each(waiters, &assert({:ok, _snapshot} = Task.await(&1)))
  end
end
