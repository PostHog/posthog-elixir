defmodule PostHog.FeatureFlags.DefinitionLoaderTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox

  alias PostHog.FeatureFlags.DefinitionLoader

  defmodule ShutdownProvider do
    @behaviour PostHog.FeatureFlags.FlagDefinitionCacheProvider

    def should_fetch_flag_definitions(_state), do: true
    def get_flag_definitions(_state), do: nil
    def on_flag_definitions_received(_state, _definitions), do: :ok

    def shutdown(owner) do
      send(owner, :provider_shutdown)
      :ok
    end
  end

  defmodule RedactedProvider do
    @behaviour PostHog.FeatureFlags.FlagDefinitionCacheProvider

    def should_fetch_flag_definitions(_state), do: false
    def get_flag_definitions(state), do: state.cached
    def on_flag_definitions_received(_state, _definitions), do: :ok

    def shutdown(state) do
      send(state.owner, :redacted_shutdown)
      :ok
    end
  end

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp config(name, overrides \\ []) do
    [
      api_key: "project-token",
      secret_key: "secret-value",
      api_client_module: PostHog.API.Mock,
      supervisor_name: name,
      test_mode: true,
      feature_flags_poll_interval_ms: 60_000
    ]
    |> Keyword.merge(overrides)
    |> PostHog.Config.validate!()
    |> Map.put(:sender_pool_size, 1)
  end

  defp envelope(key \\ "flag") do
    %{
      "flags" => [%{"key" => key, "active" => true, "filters" => %{"groups" => []}}],
      "group_type_mapping" => %{"0" => "organization"},
      "cohorts" => %{"1" => %{}}
    }
  end

  test "wire envelope includes bearer auth, query, and ETag; 304 preserves definitions" do
    test = self()

    PostHog.API.Mock
    |> stub_with(PostHog.API.Stub)
    |> expect(:request, fn :stub_client, :get, "/flags/definitions", opts ->
      send(test, {:request, opts})
      {:ok, %{status: 200, headers: %{"etag" => ["v1"]}, body: envelope()}}
    end)
    |> expect(:request, fn :stub_client, :get, "/flags/definitions", opts ->
      send(test, {:request, opts})
      {:ok, %{status: 304, headers: [{"ETag", "v2"}], body: nil}}
    end)
    |> expect(:request, fn :stub_client, :get, "/flags/definitions", opts ->
      send(test, {:request, opts})
      {:ok, %{status: 304, headers: %{}, body: nil}}
    end)

    cfg = config(__MODULE__.Wire)
    start_supervised!({PostHog.Supervisor, cfg})

    assert DefinitionLoader.ready?(__MODULE__.Wire)
    assert DefinitionLoader.definitions(__MODULE__.Wire).flags_by_key["flag"]
    assert_receive {:request, first}
    assert first[:params] == %{token: "project-token", send_cohorts: true}
    assert {"authorization", "Bearer secret-value"} in first[:headers]
    refute Keyword.has_key?(first, :json)

    loader = GenServer.whereis(PostHog.Registry.via(__MODULE__.Wire, DefinitionLoader))
    loaded_at = :sys.get_state(loader).loaded_at
    Process.sleep(1)
    assert :ok = DefinitionLoader.refresh(__MODULE__.Wire)
    assert_receive {:request, second}
    assert {"if-none-match", "v1"} in second[:headers]
    assert DateTime.compare(:sys.get_state(loader).loaded_at, loaded_at) == :gt
    assert DefinitionLoader.definitions(__MODULE__.Wire).flags_by_key["flag"]

    assert :ok = DefinitionLoader.refresh(__MODULE__.Wire)
    assert_receive {:request, third}
    assert {"if-none-match", "v2"} in third[:headers]
    refute Map.has_key?(PostHog.config(__MODULE__.Wire), :secret_key)
  end

  test "valid empty definitions are ready and transient or malformed refreshes preserve stale data" do
    stub_with(PostHog.API.Mock, PostHog.API.Stub)

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    expect(PostHog.API.Mock, :request, 3, fn :stub_client, :get, "/flags/definitions", _opts ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> {:ok, %{status: 200, body: envelope("stale"), headers: %{}}}
        1 -> {:ok, %{status: 503, body: %{}, headers: %{}}}
        2 -> {:ok, %{status: 200, body: %{"flags" => []}, headers: %{}}}
      end
    end)

    start_supervised!({PostHog.Supervisor, config(__MODULE__.Stale)})
    assert DefinitionLoader.definitions(__MODULE__.Stale).flags_by_key["stale"]

    log = capture_log(fn -> DefinitionLoader.refresh(__MODULE__.Stale) end)
    assert log =~ "HTTP 503"
    assert DefinitionLoader.definitions(__MODULE__.Stale).flags_by_key["stale"]

    log = capture_log(fn -> DefinitionLoader.refresh(__MODULE__.Stale) end)
    assert log =~ "malformed"
    assert DefinitionLoader.definitions(__MODULE__.Stale).flags_by_key["stale"]
  end

  test "auth and quota responses clear definitions while empty complete definitions remain ready" do
    stub_with(PostHog.API.Mock, PostHog.API.Stub)

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    expect(PostHog.API.Mock, :request, 3, fn :stub_client, :get, "/flags/definitions", _opts ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        1 ->
          {:ok, %{status: 401, body: %{}, headers: %{}}}

        2 ->
          {:ok,
           %{
             status: 200,
             body: %{"flags" => [], "group_type_mapping" => %{}, "cohorts" => %{}},
             headers: %{}
           }}
      end
    end)

    start_supervised!({PostHog.Supervisor, config(__MODULE__.Clear)})
    assert DefinitionLoader.ready?(__MODULE__.Clear)
    capture_log(fn -> DefinitionLoader.refresh(__MODULE__.Clear) end)
    refute DefinitionLoader.ready?(__MODULE__.Clear)
    DefinitionLoader.refresh(__MODULE__.Clear)
    assert DefinitionLoader.ready?(__MODULE__.Clear)
    assert DefinitionLoader.definitions(__MODULE__.Clear).flags == []
  end

  test "a successful 200 without ETag clears the prior API validator" do
    test = self()

    PostHog.API.Mock
    |> stub_with(PostHog.API.Stub)
    |> expect(:request, fn :stub_client, :get, "/flags/definitions", opts ->
      send(test, {:etag_request, opts})
      {:ok, %{status: 200, body: envelope(), headers: %{"etag" => "v1"}}}
    end)
    |> expect(:request, fn :stub_client, :get, "/flags/definitions", opts ->
      send(test, {:etag_request, opts})
      {:ok, %{status: 200, body: envelope(), headers: %{}}}
    end)
    |> expect(:request, fn :stub_client, :get, "/flags/definitions", opts ->
      send(test, {:etag_request, opts})
      {:ok, %{status: 304, body: nil, headers: %{}}}
    end)

    start_supervised!({PostHog.Supervisor, config(__MODULE__.EtagClear)})
    assert_receive {:etag_request, first}
    refute Enum.any?(first[:headers], &(elem(&1, 0) == "if-none-match"))

    DefinitionLoader.refresh(__MODULE__.EtagClear)
    assert_receive {:etag_request, second}
    assert {"if-none-match", "v1"} in second[:headers]

    DefinitionLoader.refresh(__MODULE__.EtagClear)
    assert_receive {:etag_request, third}
    refute Enum.any?(third[:headers], &(elem(&1, 0) == "if-none-match"))
  end

  test "transport failures preserve stale definitions and never log bearer secrets" do
    stub_with(PostHog.API.Mock, PostHog.API.Stub)
    secret = "secret-value"
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    expect(PostHog.API.Mock, :request, 2, fn :stub_client, :get, "/flags/definitions", _opts ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> {:ok, %{status: 200, body: envelope("stale"), headers: %{}}}
        1 -> {:error, %RuntimeError{message: "authorization Bearer #{secret}"}}
      end
    end)

    start_supervised!({PostHog.Supervisor, config(__MODULE__.Transport)})

    log = capture_log(fn -> DefinitionLoader.refresh(__MODULE__.Transport) end)
    assert log =~ "request failed"
    refute log =~ secret
    assert DefinitionLoader.definitions(__MODULE__.Transport).flags_by_key["stale"]
  end

  test "401, 402, and 403 clear definitions while 429 preserves stale state and backs off" do
    stub_with(PostHog.API.Mock, PostHog.API.Stub)
    statuses = [401, 402, 403, 429]
    responses = Enum.flat_map(statuses, fn status -> [:ok, status] end)
    {:ok, queue} = Agent.start_link(fn -> responses end)
    owner = self()

    expect(PostHog.API.Mock, :request, 8, fn :stub_client, :get, "/flags/definitions", _opts ->
      case Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end) do
        :ok ->
          {:ok, %{status: 200, body: envelope(), headers: %{}}}

        status ->
          send(owner, {:status_request, status})
          {:ok, %{status: status, body: %{}, headers: %{}}}
      end
    end)

    for status <- statuses do
      name = Module.concat(__MODULE__, "Status#{status}")
      start_supervised!({PostHog.Supervisor, config(name, feature_flags_poll_interval_ms: 20)})
      assert DefinitionLoader.ready?(name)
      capture_log(fn -> DefinitionLoader.refresh(name) end)
      assert_receive {:status_request, ^status}

      if status == 429 do
        assert DefinitionLoader.ready?(name)
        refute_receive {:status_request, 429}, 100
      else
        refute DefinitionLoader.ready?(name)
      end

      stop_supervised(name)
    end
  end

  test "named instances keep independent immutable definition state" do
    stub_with(PostHog.API.Mock, PostHog.API.Stub)

    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 200, body: envelope("first"), headers: %{}}}
    end)

    start_supervised!({PostHog.Supervisor, config(__MODULE__.First)})
    assert DefinitionLoader.definitions(__MODULE__.First).flags_by_key["first"]

    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 200, body: envelope("second"), headers: %{}}}
    end)

    start_supervised!({PostHog.Supervisor, config(__MODULE__.Second)})
    assert DefinitionLoader.definitions(__MODULE__.First).flags_by_key["first"]
    refute DefinitionLoader.definitions(__MODULE__.First).flags_by_key["second"]
    assert DefinitionLoader.definitions(__MODULE__.Second).flags_by_key["second"]
  end

  test "registry config redacts privileged key and provider state" do
    stub_with(PostHog.API.Mock, PostHog.API.Stub)
    sentinel = {:do_not_expose, make_ref()}

    cfg =
      config(__MODULE__.Redacted,
        enable_local_evaluation: false,
        flag_definition_cache_provider: {ShutdownProvider, sentinel}
      )

    start_supervised!({PostHog.Supervisor, cfg})
    public = PostHog.config(__MODULE__.Redacted)
    refute Map.has_key?(public, :secret_key)
    refute Map.has_key?(public, :flag_definition_cache_provider)
    refute inspect(public) =~ inspect(sentinel)
  end

  test "concurrent manual refreshes are serialized without overlapping API loads" do
    stub_with(PostHog.API.Mock, PostHog.API.Stub)
    {:ok, activity} = Agent.start_link(fn -> %{active: 0, max: 0} end)

    expect(PostHog.API.Mock, :request, 6, fn :stub_client, :get, "/flags/definitions", _opts ->
      Agent.update(activity, fn state ->
        active = state.active + 1
        %{state | active: active, max: max(state.max, active)}
      end)

      Process.sleep(5)
      Agent.update(activity, &%{&1 | active: &1.active - 1})
      {:ok, %{status: 200, body: envelope(), headers: %{}}}
    end)

    start_supervised!({PostHog.Supervisor, config(__MODULE__.Serialized)})
    assert DefinitionLoader.ready?(__MODULE__.Serialized)

    1..5
    |> Enum.map(fn _index ->
      Task.async(fn -> DefinitionLoader.refresh(__MODULE__.Serialized) end)
    end)
    |> Task.await_many()

    assert Agent.get(activity, & &1.max) == 1
  end

  test "blocked definition requests are canceled before bounded shutdown and provider cleanup" do
    owner = self()
    stub_with(PostHog.API.Mock, PostHog.API.Stub)

    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      send(owner, :definition_request_started)
      receive do: (:never -> :ok)
    end)

    cfg =
      config(__MODULE__.Blocked,
        flag_definition_request_timeout_ms: 40,
        flag_definition_cache_provider_timeout_ms: 40,
        flag_definition_cache_provider: {ShutdownProvider, owner}
      )

    start_supervised!({PostHog.Supervisor, cfg})
    assert_receive :definition_request_started
    started = System.monotonic_time(:millisecond)
    assert :ok = stop_supervised(__MODULE__.Blocked)
    assert System.monotonic_time(:millisecond) - started < 500
    assert_receive :provider_shutdown
  end

  test "loader state and child start MFA redact secret and provider sentinels" do
    stub_with(PostHog.API.Mock, PostHog.API.Stub)
    secret = "secret-sentinel-#{System.unique_integer()}"
    provider_sentinel = "provider-sentinel-#{System.unique_integer()}"

    provider = %{
      owner: self(),
      sentinel: provider_sentinel,
      cached: envelope("redacted")
    }

    cfg =
      config(__MODULE__.Inspect,
        secret_key: secret,
        flag_definition_cache_provider: {RedactedProvider, provider}
      )

    spec = DefinitionLoader.child_spec(config: cfg, callers: [self()])
    refute inspect(spec) =~ secret
    refute inspect(spec) =~ provider_sentinel

    start_supervised!({PostHog.Supervisor, cfg})
    assert DefinitionLoader.ready?(__MODULE__.Inspect)
    loader = GenServer.whereis(PostHog.Registry.via(__MODULE__.Inspect, DefinitionLoader))
    refute inspect(:sys.get_state(loader)) =~ secret
    refute inspect(:sys.get_state(loader)) =~ provider_sentinel
    stop_supervised(__MODULE__.Inspect)
    assert_receive :redacted_shutdown
  end

  test "child shutdown budget covers request and three serial provider boundaries" do
    stub_with(PostHog.API.Mock, PostHog.API.Stub)

    cfg =
      config(__MODULE__.Budget,
        flag_definition_request_timeout_ms: 11,
        flag_definition_cache_provider_timeout_ms: 13
      )

    spec = DefinitionLoader.child_spec(config: cfg, callers: [])
    assert spec.shutdown == 11 + 3 * 13 + 1_000
  end

  test "429 backoff never schedules sooner than a long configured baseline" do
    stub_with(PostHog.API.Mock, PostHog.API.Stub)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    expect(PostHog.API.Mock, :request, 2, fn :stub_client, :get, "/flags/definitions", _opts ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> {:ok, %{status: 200, body: envelope(), headers: %{}}}
        1 -> {:ok, %{status: 429, body: %{}, headers: %{}}}
      end
    end)

    baseline = 120_000

    start_supervised!(
      {PostHog.Supervisor,
       config(__MODULE__.LongBackoff, feature_flags_poll_interval_ms: baseline)}
    )

    capture_log(fn -> DefinitionLoader.refresh(__MODULE__.LongBackoff) end)
    loader = GenServer.whereis(PostHog.Registry.via(__MODULE__.LongBackoff, DefinitionLoader))
    state = :sys.get_state(loader)
    assert state.quota_backoff_ms >= baseline
    assert Process.read_timer(state.timer_ref) >= baseline - 100
  end

  test "stale timers, late boundary messages, DOWN signals, and stray messages are ignored" do
    stub(PostHog.API.Mock, :client, fn _api_key, _host ->
      %PostHog.API.Client{client: :stub_client, module: PostHog.API.Mock}
    end)

    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 200, body: envelope(), headers: %{}}}
    end)

    start_supervised!({PostHog.Supervisor, config(__MODULE__.LateMessages)})
    assert DefinitionLoader.ready?(__MODULE__.LateMessages)
    loader = GenServer.whereis(PostHog.Registry.via(__MODULE__.LateMessages, DefinitionLoader))
    state = :sys.get_state(loader)
    send(loader, {:refresh, state.timer_generation - 1})
    send(loader, {:boundary_result, make_ref(), self(), {:ok, :late}})
    send(loader, {:DOWN, make_ref(), :process, self(), :normal})
    send(loader, {:unexpected, :message})
    Process.sleep(10)
    assert Process.alive?(loader)
    assert DefinitionLoader.ready?(__MODULE__.LateMessages)
  end

  test "poll timer refreshes and disabled, no-secret, and local-disabled instances start no loader" do
    test = self()
    stub_with(PostHog.API.Mock, PostHog.API.Stub)

    expect(PostHog.API.Mock, :request, 2, fn :stub_client, :get, "/flags/definitions", _opts ->
      send(test, :loaded)
      {:ok, %{status: 200, body: envelope(), headers: %{}}}
    end)

    start_supervised!(
      {PostHog.Supervisor, config(__MODULE__.Timer, feature_flags_poll_interval_ms: 20)}
    )

    assert_receive :loaded
    assert_receive :loaded, 200

    for {name, overrides} <- [
          {__MODULE__.NoSecret, [secret_key: nil]},
          {__MODULE__.LocalDisabled, [enable_local_evaluation: false]},
          {__MODULE__.Disabled, [api_key: ""]}
        ] do
      cfg = config(name, overrides)
      start_supervised!({PostHog.Supervisor, cfg})
      assert Process.whereis(PostHog.Registry.registry_name(name))
      assert GenServer.whereis(PostHog.Registry.via(name, DefinitionLoader)) == nil
    end
  end
end
