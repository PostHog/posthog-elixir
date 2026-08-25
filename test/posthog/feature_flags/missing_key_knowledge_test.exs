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

    assert MapSet.member?(
             DefinitionLoader.evaluation_state(__MODULE__.Ordering, ["a"]).known_missing,
             "a"
           )

    delayed = Task.async(fn -> scoped(__MODULE__.Ordering, ["a", "b"], "delayed") end)
    assert_receive {:delayed_omission, delayed_worker}

    assert {:ok, positive} = scoped(__MODULE__.Ordering, ["a", "c"], "positive")
    assert positive.flags["a"].enabled

    send(delayed_worker, :release_delayed_omission)
    assert {:ok, _snapshot} = Task.await(delayed)

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

    assert :stale_generation =
             DefinitionLoader.update_negative_knowledge(
               __MODULE__.Restart,
               old_generation,
               ["missing"],
               [],
               true
             )

    assert MapSet.new() ==
             DefinitionLoader.evaluation_state(__MODULE__.Restart, ["missing"]).known_missing
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

    refute MapSet.member?(
             DefinitionLoader.evaluation_state(__MODULE__.Capacity, [returned]).known_missing,
             returned
           )

    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 304, body: nil, headers: %{}}}
    end)

    DefinitionLoader.refresh(__MODULE__.Capacity)

    assert :stale_generation =
             DefinitionLoader.update_negative_knowledge(
               __MODULE__.Capacity,
               initial.generation,
               ["race"],
               [],
               true
             )

    assert MapSet.size(DefinitionLoader.evaluation_state(__MODULE__.Capacity, keys).known_missing) ==
             0
  end
end
