defmodule PostHog.FeatureFlags.FlagDefinitionCacheProviderTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox

  alias PostHog.FeatureFlags.DefinitionLoader

  defmodule Provider do
    @behaviour PostHog.FeatureFlags.FlagDefinitionCacheProvider

    @impl true
    def should_fetch_flag_definitions(agent), do: run(agent, :decision)
    @impl true
    def get_flag_definitions(agent), do: run(agent, :read)

    @impl true
    def on_flag_definitions_received(agent, definitions) do
      send(Agent.get(agent, & &1.owner), {:stored, definitions})
      run(agent, :store)
    end

    @impl true
    def shutdown(agent) do
      send(Agent.get(agent, & &1.owner), :shutdown)
      run(agent, :shutdown)
    end

    defp run(agent, key) do
      case Agent.get(agent, &Map.fetch!(&1, key)) do
        {:sleep, milliseconds, result} ->
          Process.sleep(milliseconds)
          result

        {:raise, message} ->
          raise message

        value ->
          value
      end
    end
  end

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp envelope(key) do
    %{
      "flags" => [%{"key" => key, "active" => true, "filters" => %{"groups" => []}}],
      "group_type_mapping" => %{"0" => "organization"},
      "cohorts" => %{},
      "minimal_flag_called_events" => true
    }
  end

  defp start_instance(name, provider, overrides \\ []) do
    cfg =
      [
        api_key: "token",
        secret_key: "secret",
        supervisor_name: name,
        api_client_module: PostHog.API.Mock,
        test_mode: true,
        flag_definition_cache_provider: {Provider, provider},
        feature_flags_poll_interval_ms: 60_000,
        flag_definition_cache_provider_timeout_ms: 20
      ]
      |> Keyword.merge(overrides)
      |> PostHog.Config.validate!()
      |> Map.put(:sender_pool_size, 1)

    start_supervised!({PostHog.Supervisor, cfg})
  end

  test "negative decision reads complete cached definitions without an API request" do
    stub_with(PostHog.API.Mock, PostHog.API.Stub)

    owner = self()

    {:ok, provider} =
      Agent.start_link(fn ->
        %{owner: owner, decision: false, read: envelope("cached"), store: :ok, shutdown: :ok}
      end)

    start_instance(__MODULE__.Cached, provider)

    definitions = DefinitionLoader.definitions(__MODULE__.Cached)
    assert definitions.flags_by_key["cached"]
    assert definitions.group_type_mapping == %{"0" => "organization"}
    assert definitions.minimal_flag_called_events
    assert :ok = stop_supervised(__MODULE__.Cached)
    assert_receive :shutdown
  end

  test "positive decision fetches, publishes, and stores the complete envelope" do
    stub_with(PostHog.API.Mock, PostHog.API.Stub)

    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 200, body: envelope("fresh"), headers: %{}}}
    end)

    owner = self()

    {:ok, provider} =
      Agent.start_link(fn ->
        %{owner: owner, decision: true, read: nil, store: :ok, shutdown: :ok}
      end)

    start_instance(__MODULE__.Fresh, provider)

    assert DefinitionLoader.definitions(__MODULE__.Fresh).flags_by_key["fresh"]
    assert_receive {:stored, stored}
    assert stored["flags"] != []
    assert stored["group_type_mapping"] == %{"0" => "organization"}
    assert stored["cohorts"] == %{}
    assert stored["minimal_flag_called_events"]
    assert :ok = stop_supervised(__MODULE__.Fresh)
    assert_receive :shutdown
  end

  test "negative decision preserves stale memory on empty, failed, timed out, or malformed reads" do
    owner = self()
    stub_with(PostHog.API.Mock, PostHog.API.Stub)

    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 200, body: envelope("stale"), headers: %{}}}
    end)

    stub(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      send(owner, :unexpected_api_fetch)
      {:ok, %{status: 200, body: envelope("unexpected"), headers: %{}}}
    end)

    {:ok, provider} =
      Agent.start_link(fn ->
        %{owner: owner, decision: true, read: nil, store: :ok, shutdown: :ok}
      end)

    start_instance(__MODULE__.StaleReads, provider)
    assert DefinitionLoader.definitions(__MODULE__.StaleReads).flags_by_key["stale"]
    assert_receive {:stored, _definitions}

    for read <- [nil, {:raise, "read"}, {:sleep, 100, nil}, %{"flags" => []}] do
      Agent.update(provider, &%{&1 | decision: false, read: read})
      capture_log(fn -> DefinitionLoader.refresh(__MODULE__.StaleReads) end)
      assert DefinitionLoader.definitions(__MODULE__.StaleReads).flags_by_key["stale"]
      refute_receive :unexpected_api_fetch
    end

    stop_supervised(__MODULE__.StaleReads)
    assert_receive :shutdown
  end

  test "empty cache without memory performs an emergency fetch but does not store without ownership" do
    owner = self()
    stub_with(PostHog.API.Mock, PostHog.API.Stub)

    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 200, body: envelope("emergency"), headers: %{}}}
    end)

    {:ok, provider} =
      Agent.start_link(fn ->
        %{owner: owner, decision: false, read: nil, store: :ok, shutdown: :ok}
      end)

    start_instance(__MODULE__.Emergency, provider)
    assert DefinitionLoader.definitions(__MODULE__.Emergency).flags_by_key["emergency"]
    refute_receive {:stored, _definitions}
    stop_supervised(__MODULE__.Emergency)
    assert_receive :shutdown
  end

  test "provider-installed data clears the API ETag before a later owned fetch" do
    owner = self()
    stub_with(PostHog.API.Mock, PostHog.API.Stub)

    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", opts ->
      refute {"if-none-match", "api-v1"} in opts[:headers]
      {:ok, %{status: 200, body: envelope("api"), headers: %{"etag" => "api-v1"}}}
    end)

    {:ok, provider} =
      Agent.start_link(fn ->
        %{owner: owner, decision: true, read: envelope("cached"), store: :ok, shutdown: :ok}
      end)

    start_instance(__MODULE__.ProviderEtag, provider)
    assert_receive {:stored, _definitions}

    Agent.update(provider, &%{&1 | decision: false})
    DefinitionLoader.refresh(__MODULE__.ProviderEtag)
    assert DefinitionLoader.definitions(__MODULE__.ProviderEtag).flags_by_key["cached"]

    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", opts ->
      refute Enum.any?(opts[:headers], &(elem(&1, 0) == "if-none-match"))
      {:ok, %{status: 200, body: envelope("api-again"), headers: %{}}}
    end)

    Agent.update(provider, &%{&1 | decision: true})
    DefinitionLoader.refresh(__MODULE__.ProviderEtag)
    assert DefinitionLoader.definitions(__MODULE__.ProviderEtag).flags_by_key["api-again"]
    stop_supervised(__MODULE__.ProviderEtag)
    assert_receive :shutdown
  end

  test "store timeout leaves fresh memory usable and callbacks remain exactly once" do
    owner = self()
    stub_with(PostHog.API.Mock, PostHog.API.Stub)

    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 200, body: envelope("fresh-after-timeout"), headers: %{}}}
    end)

    {:ok, provider} =
      Agent.start_link(fn ->
        %{
          owner: owner,
          decision: true,
          read: nil,
          store: {:sleep, 100, :ok},
          shutdown: :ok
        }
      end)

    log =
      capture_log(fn ->
        start_instance(__MODULE__.StoreTimeout, provider)

        assert DefinitionLoader.definitions(__MODULE__.StoreTimeout).flags_by_key[
                 "fresh-after-timeout"
               ]
      end)

    assert log =~ "on_flag_definitions_received failed (timeout)"
    assert_receive {:stored, _definitions}
    refute_receive {:stored, _definitions}
    assert :ok = stop_supervised(__MODULE__.StoreTimeout)
    assert_receive :shutdown
    refute_receive :shutdown
  end

  test "decision timeout falls back directly, store failure keeps memory, and shutdown is contained" do
    stub_with(PostHog.API.Mock, PostHog.API.Stub)

    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 200, body: envelope("fallback"), headers: %{}}}
    end)

    owner = self()

    {:ok, provider} =
      Agent.start_link(fn ->
        %{
          owner: owner,
          decision: {:sleep, 100, false},
          read: nil,
          store: {:raise, "store"},
          shutdown: {:raise, "shutdown"}
        }
      end)

    log =
      capture_log(fn ->
        start_instance(__MODULE__.Failures, provider)
        assert DefinitionLoader.definitions(__MODULE__.Failures).flags_by_key["fallback"]
        assert :ok = Supervisor.terminate_child(__MODULE__.Failures, DefinitionLoader)
        assert :ok = stop_supervised(__MODULE__.Failures)
      end)

    assert log =~ "should_fetch_flag_definitions failed"
    assert log =~ "on_flag_definitions_received failed"
    assert log =~ "shutdown failed"
    assert_receive :shutdown
    refute_receive :shutdown
  end
end
