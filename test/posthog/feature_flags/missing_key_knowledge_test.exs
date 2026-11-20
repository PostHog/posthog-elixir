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

  test "waiters of an errored probe make their own requests in parallel" do
    owner = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    expect(PostHog.API.Mock, :request, 5, fn :stub_client, method, path, _opts ->
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
      for id <- ["two", "three", "four"], do: Task.async(fn -> scoped(name, ["missing"], id) end)

    eventually(fn ->
      map_size(Map.get(:sys.get_state(coordinator).waiters, "missing", %{})) == 3
    end)

    send(first_worker, :release_errored)
    assert {:ok, _snapshot} = Task.await(first)

    workers =
      for call <- 1..3 do
        assert_receive {:errored_probe, ^call, worker}
        worker
      end

    Enum.each(workers, &send(&1, :release_errored))
    Enum.each(waiters, &assert({:ok, _snapshot} = Task.await(&1)))
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

  test "a key /flags already returned is requested directly without waiting on a probe" do
    owner = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    stub(PostHog.API.Mock, :request, fn :stub_client, method, path, _opts ->
      case {method, path} do
        {:get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags"} ->
          call = Agent.get_and_update(calls, &{&1, &1 + 1})
          send(owner, {:present_probe, call, self()})
          if call == 1, do: receive(do: (:release_present -> :ok))
          {:ok, %{status: 200, body: %{"flags" => %{"remote" => %{"enabled" => true}}}}}
      end
    end)

    name = __MODULE__.KnownPresent
    start_instance(name)

    # The first request confirms the key exists.
    assert {:ok, first} = scoped(name, ["remote"], "one")
    assert first.flags["remote"].enabled
    assert_receive {:present_probe, 0, _worker}

    # A later request for that key is in flight, and another caller doesn't wait for it.
    stalled = Task.async(fn -> scoped(name, ["remote"], "two") end)
    assert_receive {:present_probe, 1, stalled_worker}
    direct = Task.async(fn -> scoped(name, ["remote"], "three") end)
    assert_receive {:present_probe, 2, _worker}, 500
    assert {:ok, snapshot} = Task.await(direct, 500)
    assert snapshot.flags["remote"].enabled

    send(stalled_worker, :release_present)
    assert {:ok, _snapshot} = Task.await(stalled)
  end

  test "a clean omission of a known-present key makes it unknown again" do
    owner = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    stub(PostHog.API.Mock, :request, fn :stub_client, method, path, _opts ->
      case {method, path} do
        {:get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags"} ->
          call = Agent.get_and_update(calls, &{&1, &1 + 1})
          send(owner, {:deleted_probe, call, self()})

          if call == 0,
            do: {:ok, %{status: 200, body: %{"flags" => %{"remote" => %{"enabled" => true}}}}},
            else: {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end
    end)

    name = __MODULE__.PresentThenDeleted
    start_instance(name)

    assert {:ok, _snapshot} = scoped(name, ["remote"], "one")
    assert_receive {:deleted_probe, 0, _worker}
    sync_loader(name)

    assert MapSet.member?(
             DefinitionLoader.evaluation_state(name, ["remote"]).known_present,
             "remote"
           )

    # The flag is deleted. A clean omission moves it back to unknown, then missing.
    assert {:ok, snapshot} = scoped(name, ["remote"], "two")
    assert Evaluations.keys(snapshot) == []
    assert_receive {:deleted_probe, 1, _worker}
    sync_loader(name)

    state = DefinitionLoader.evaluation_state(name, ["remote"])
    refute MapSet.member?(state.known_present, "remote")
    assert MapSet.member?(state.known_missing, "remote")

    assert {:ok, _snapshot} = scoped(name, ["remote"], "three")
    refute_receive {:deleted_probe, 2, _worker}, 50
  end

  test "an oversized request still updates a known-present key it omits" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    unknown = for index <- 0..1_000, do: "unknown-#{index}"

    stub(PostHog.API.Mock, :request, fn :stub_client, method, path, _opts ->
      case {method, path} do
        {:get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags"} ->
          if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0,
            do: {:ok, %{status: 200, body: %{"flags" => %{"remote" => %{"enabled" => true}}}}},
            else: {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end
    end)

    name = __MODULE__.OversizedPresent
    start_instance(name)
    assert {:ok, _snapshot} = scoped(name, ["remote"], "one")
    sync_loader(name)

    assert MapSet.member?(
             DefinitionLoader.evaluation_state(name, ["remote"]).known_present,
             "remote"
           )

    assert {:ok, _snapshot} = scoped(name, ["remote" | unknown], "two")
    sync_loader(name)

    refute MapSet.member?(
             DefinitionLoader.evaluation_state(name, ["remote"]).known_present,
             "remote"
           )
  end

  test "a coordinated clean omission clears a known-present key past the missing-key limit" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    unknown = for index <- 1..1_000, do: "z-#{String.pad_leading(to_string(index), 4, "0")}"

    stub(PostHog.API.Mock, :request, fn :stub_client, method, path, _opts ->
      case {method, path} do
        {:get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags"} ->
          if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0,
            do: {:ok, %{status: 200, body: %{"flags" => %{"a-retired" => %{"enabled" => true}}}}},
            else: {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end
    end)

    name = __MODULE__.PresentPastLimit
    start_instance(name)
    assert {:ok, _snapshot} = scoped(name, ["a-retired"], "one")
    sync_loader(name)

    assert MapSet.member?(
             DefinitionLoader.evaluation_state(name, ["a-retired"]).known_present,
             "a-retired"
           )

    # 1,000 unknown keys stay within the coordination limit, so this request is coordinated.
    assert {:ok, _snapshot} = scoped(name, ["a-retired" | unknown], "two")
    sync_loader(name)

    refute MapSet.member?(
             DefinitionLoader.evaluation_state(name, ["a-retired"]).known_present,
             "a-retired"
           )
  end

  test "a definitions refresh forgets known-present keys" do
    stub(PostHog.API.Mock, :request, fn :stub_client, method, path, _opts ->
      case {method, path} do
        {:get, "/flags/definitions"} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags"} ->
          {:ok, %{status: 200, body: %{"flags" => %{"remote" => %{"enabled" => true}}}}}
      end
    end)

    name = __MODULE__.PresentRefresh
    start_instance(name)
    assert {:ok, _snapshot} = scoped(name, ["remote"], "one")
    sync_loader(name)

    assert MapSet.member?(
             DefinitionLoader.evaluation_state(name, ["remote"]).known_present,
             "remote"
           )

    DefinitionLoader.refresh(name)
    assert DefinitionLoader.evaluation_state(name, ["remote"]).known_present == MapSet.new()
  end

  defp waiting_on(name, key) do
    coordinator = PostHog.Registry.via(name, FeatureFlags.MissingProbeCoordinator)
    map_size(Map.get(:sys.get_state(coordinator).waiters, key, %{}))
  end

  defp record(name, generation, requested, returned, clean? \\ true) do
    started = DefinitionLoader.probe_started(name)

    :ok =
      DefinitionLoader.update_negative_knowledge(
        name,
        generation,
        requested,
        returned,
        clean?,
        started
      )
  end

  test "clearing a known-present key keeps it protected from older omissions" do
    stub(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 200, body: envelope(), headers: %{}}}
    end)

    name = __MODULE__.PresenceHistory
    start_instance(name)
    %{generation: generation} = DefinitionLoader.evaluation_state(name, [])
    unknown = for index <- 1..1_000, do: "z-#{String.pad_leading(to_string(index), 4, "0")}"

    # An older probe for "a-retired" starts, then a newer response returns it.
    older = DefinitionLoader.probe_started(name)
    record(name, generation, [], ["a-retired"])

    # A later request omits it alongside 1,000 keys, so it no longer fits as missing.
    record(name, generation, ["a-retired" | unknown], [])
    state = DefinitionLoader.evaluation_state(name, ["a-retired"])
    refute MapSet.member?(state.known_present, "a-retired")
    refute MapSet.member?(state.known_missing, "a-retired")

    # The older probe's omission predates the return, so it can't record absence.
    :ok =
      DefinitionLoader.update_negative_knowledge(
        name,
        generation,
        ["a-retired"],
        [],
        true,
        older
      )

    refute MapSet.member?(
             DefinitionLoader.evaluation_state(name, ["a-retired"]).known_missing,
             "a-retired"
           )
  end

  test "a waiter's omission clears a key another caller returned while it waited" do
    owner = self()

    stub(PostHog.API.Mock, :request, fn :stub_client, method, path, opts ->
      case {method, path, opts[:json][:distinct_id]} do
        {:get, "/flags/definitions", _id} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags", "one"} ->
          send(owner, {:returning_owner, self()})
          receive do: (:release_owner -> :ok)
          {:ok, %{status: 200, body: %{"flags" => %{"k" => %{"enabled" => true}}}}}

        {:post, "/flags", "two"} ->
          {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end
    end)

    name = __MODULE__.ReturnedWhileWaiting
    start_instance(name)
    first = Task.async(fn -> scoped(name, ["k"], "one") end)
    assert_receive {:returning_owner, worker}
    second = Task.async(fn -> scoped(name, ["k"], "two") end)
    eventually(fn -> waiting_on(name, "k") == 1 end)

    send(worker, :release_owner)
    assert {:ok, _snapshot} = Task.await(first)
    assert {:ok, _snapshot} = Task.await(second)
    sync_loader(name)

    state = DefinitionLoader.evaluation_state(name, ["k"])
    refute MapSet.member?(state.known_present, "k")
    assert MapSet.member?(state.known_missing, "k")
  end

  test "a waiter doesn't reinstall absence for a key that became missing while it waited" do
    owner = self()

    stub(PostHog.API.Mock, :request, fn :stub_client, method, path, opts ->
      case {method, path, opts[:json][:distinct_id]} do
        {:get, "/flags/definitions", _id} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags", "holder"} ->
          send(owner, {:holder, self()})
          receive do: (:release_holder -> :ok)
          {:ok, %{status: 200, body: %{"flags" => %{}, "errorsWhileComputingFlags" => true}}}

        {:post, "/flags", "mixed"} ->
          send(owner, {:mixed, self()})
          receive do: (:release_mixed -> :ok)
          {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end
    end)

    name = __MODULE__.MissingWhileWaiting
    start_instance(name)
    %{generation: generation} = DefinitionLoader.evaluation_state(name, [])
    record(name, generation, [], ["a"])

    holder = Task.async(fn -> scoped(name, ["b"], "holder") end)
    assert_receive {:holder, holder_worker}
    mixed = Task.async(fn -> scoped(name, ["a", "b"], "mixed") end)
    eventually(fn -> waiting_on(name, "b") == 1 end)

    # "a" becomes known missing while the mixed call waits on "b".
    record(name, generation, ["a"], [])
    assert MapSet.member?(DefinitionLoader.evaluation_state(name, ["a"]).known_missing, "a")

    send(holder_worker, :release_holder)
    assert {:ok, _snapshot} = Task.await(holder)
    assert_receive {:mixed, mixed_worker}

    # The negative entry is evicted while the mixed fallback is in flight.
    evicting = for index <- 1..1_000, do: "z-#{String.pad_leading(to_string(index), 4, "0")}"
    record(name, generation, evicting, [])
    refute MapSet.member?(DefinitionLoader.evaluation_state(name, ["a"]).known_missing, "a")

    send(mixed_worker, :release_mixed)
    assert {:ok, _snapshot} = Task.await(mixed)
    sync_loader(name)

    refute MapSet.member?(DefinitionLoader.evaluation_state(name, ["a"]).known_missing, "a")
  end

  test "a waiter doesn't record absence for a key that gained a local definition while it waited" do
    owner = self()
    {:ok, definition_calls} = Agent.start_link(fn -> 0 end)

    defined =
      envelope([
        %{
          "key" => "a",
          "active" => true,
          "ensure_experience_continuity" => true,
          "filters" => %{"groups" => []}
        }
      ])

    stub(PostHog.API.Mock, :request, fn :stub_client, method, path, opts ->
      case {method, path, opts[:json][:distinct_id]} do
        {:get, "/flags/definitions", _id} ->
          body =
            if Agent.get_and_update(definition_calls, &{&1, &1 + 1}) == 0,
              do: envelope(),
              else: defined

          {:ok, %{status: 200, body: body, headers: %{}}}

        {:post, "/flags", "holder"} ->
          send(owner, {:holder, self()})
          receive do: (:release_holder -> :ok)
          {:ok, %{status: 200, body: %{"flags" => %{}, "errorsWhileComputingFlags" => true}}}

        {:post, "/flags", "single"} ->
          send(owner, :single_requested)
          {:ok, %{status: 200, body: %{"flags" => %{"a" => %{"enabled" => true}}}}}

        {:post, "/flags", _id} ->
          {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end
    end)

    name = __MODULE__.DefinedWhileWaiting
    start_instance(name)
    %{generation: generation} = DefinitionLoader.evaluation_state(name, [])
    record(name, generation, [], ["a"])

    holder = Task.async(fn -> scoped(name, ["b"], "holder") end)
    assert_receive {:holder, holder_worker}
    mixed = Task.async(fn -> scoped(name, ["a", "b"], "mixed") end)
    eventually(fn -> waiting_on(name, "b") == 1 end)

    # A refresh installs a definition for "a" that still needs remote evaluation.
    DefinitionLoader.refresh(name)

    send(holder_worker, :release_holder)
    assert {:ok, _snapshot} = Task.await(holder)
    assert {:ok, _snapshot} = Task.await(mixed)
    sync_loader(name)

    refute MapSet.member?(DefinitionLoader.evaluation_state(name, ["a"]).known_missing, "a")
    assert {:ok, _snapshot} = scoped(name, ["a"], "single")
    assert_receive :single_requested
  end

  test "a waiter coordinates on a key that became unknown while it waited" do
    owner = self()
    {:ok, definition_calls} = Agent.start_link(fn -> 0 end)

    stub(PostHog.API.Mock, :request, fn :stub_client, method, path, opts ->
      case {method, path, opts[:json][:distinct_id]} do
        {:get, "/flags/definitions", _id} ->
          Agent.update(definition_calls, &(&1 + 1))
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags", "b-owner"} ->
          send(owner, {:b_owner, self()})
          receive do: (:release_b -> :ok)
          {:ok, %{status: 200, body: %{"flags" => %{}, "errorsWhileComputingFlags" => true}}}

        {:post, "/flags", "a-owner"} ->
          send(owner, {:a_owner, self()})
          receive do: (:release_a -> :ok)
          {:ok, %{status: 200, body: %{"flags" => %{}}}}

        {:post, "/flags", "mixed"} ->
          send(owner, :mixed_requested)
          {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end
    end)

    name = __MODULE__.UnknownAfterWait
    start_instance(name)
    %{generation: generation} = DefinitionLoader.evaluation_state(name, [])
    record(name, generation, [], ["a"])

    b_owner = Task.async(fn -> scoped(name, ["b"], "b-owner") end)
    assert_receive {:b_owner, b_worker}
    mixed = Task.async(fn -> scoped(name, ["a", "b"], "mixed") end)
    eventually(fn -> waiting_on(name, "b") == 1 end)

    # A refresh clears "a"'s presence, and another call starts checking "a".
    DefinitionLoader.refresh(name)
    a_owner = Task.async(fn -> scoped(name, ["a"], "a-owner") end)
    assert_receive {:a_owner, a_worker}

    # When "b" settles, the mixed call waits on the check for "a" instead of
    # sending its request right away.
    send(b_worker, :release_b)
    assert {:ok, _snapshot} = Task.await(b_owner)
    eventually(fn -> waiting_on(name, "a") == 1 end)
    refute_received :mixed_requested

    # The check for "a" cleanly omits it, so the mixed call requests only for "b".
    send(a_worker, :release_a)
    assert {:ok, _snapshot} = Task.await(a_owner)
    assert {:ok, _snapshot} = Task.await(mixed)
    assert_receive :mixed_requested
  end

  test "an older direct request's omission doesn't clear a newer return" do
    owner = self()

    stub(PostHog.API.Mock, :request, fn :stub_client, method, path, opts ->
      case {method, path, opts[:json][:distinct_id]} do
        {:get, "/flags/definitions", _id} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags", "older"} ->
          send(owner, {:older, self()})
          receive do: (:release_older -> :ok)
          {:ok, %{status: 200, body: %{"flags" => %{}}}}

        {:post, "/flags", _id} ->
          {:ok, %{status: 200, body: %{"flags" => %{"k" => %{"enabled" => true}}}}}
      end
    end)

    name = __MODULE__.OlderDirectOmission
    start_instance(name)
    assert {:ok, _snapshot} = scoped(name, ["k"], "first")
    sync_loader(name)
    assert MapSet.member?(DefinitionLoader.evaluation_state(name, ["k"]).known_present, "k")

    # Two direct requests for known-present "k" overlap. The newer one returns it.
    older = Task.async(fn -> scoped(name, ["k"], "older") end)
    assert_receive {:older, older_worker}
    assert {:ok, _snapshot} = scoped(name, ["k"], "newer")

    # The older request finishes last with a clean omission.
    send(older_worker, :release_older)
    assert {:ok, _snapshot} = Task.await(older)
    sync_loader(name)

    state = DefinitionLoader.evaluation_state(name, ["k"])
    assert MapSet.member?(state.known_present, "k")
    refute MapSet.member?(state.known_missing, "k")
  end

  test "a later coordination round respects the coordination limit" do
    owner = self()
    present = for index <- 1..1_000, do: "p-#{String.pad_leading(to_string(index), 4, "0")}"
    missing = for index <- 1..1_000, do: "m-#{String.pad_leading(to_string(index), 4, "0")}"

    stub(PostHog.API.Mock, :request, fn :stub_client, method, path, opts ->
      case {method, path, opts[:json][:distinct_id]} do
        {:get, "/flags/definitions", _id} ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        {:post, "/flags", "b-owner"} ->
          send(owner, {:b_owner, self()})
          receive do: (:release_b -> :ok)
          {:ok, %{status: 200, body: %{"flags" => %{}, "errorsWhileComputingFlags" => true}}}

        {:post, "/flags", "mixed"} ->
          send(owner, {:mixed, self()})
          receive do: (:release_mixed -> :ok)
          {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end
    end)

    name = __MODULE__.LaterRoundLimit
    start_instance(name)
    %{generation: generation} = DefinitionLoader.evaluation_state(name, [])
    record(name, generation, [], present)
    record(name, generation, missing, [])

    b_owner = Task.async(fn -> scoped(name, ["b"], "b-owner") end)
    assert_receive {:b_owner, b_worker}
    mixed = Task.async(fn -> scoped(name, ["b" | present ++ missing], "mixed") end)
    eventually(fn -> waiting_on(name, "b") == 1 end)

    # A refresh makes 2,000 keys unknown while the mixed call waits on "b".
    DefinitionLoader.refresh(name)
    send(b_worker, :release_b)
    assert {:ok, _snapshot} = Task.await(b_owner)

    # Too many new keys to coordinate, so the mixed call requests without claiming them.
    assert_receive {:mixed, mixed_worker}, 1_000
    coordinator = PostHog.Registry.via(name, FeatureFlags.MissingProbeCoordinator)
    assert :sys.get_state(coordinator).owners == %{}
    send(mixed_worker, :release_mixed)
    assert {:ok, _snapshot} = Task.await(mixed)
  end
end
