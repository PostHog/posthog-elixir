defmodule PostHog.FeatureFlags.DefinitionLoaderWarningTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox

  alias PostHog.FeatureFlags
  alias PostHog.FeatureFlags.{DefinitionLoader, Evaluations}

  defmodule Provider do
    @behaviour PostHog.FeatureFlags.FlagDefinitionCacheProvider

    def should_fetch_flag_definitions(_state), do: false
    def get_flag_definitions(agent), do: Agent.get(agent, & &1.body)
    def on_flag_definitions_received(_state, _definitions), do: :ok
    def shutdown(_state), do: :ok
  end

  setup :set_mox_from_context
  setup :verify_on_exit!

  for source <- [:api, :cache], runtime_key <- ["evaluation_runtime", :evaluation_runtime] do
    test "#{source} loads with #{inspect(runtime_key)} warn only for nonclient definitions and preserve local evaluation" do
      source = unquote(source)
      runtime_key = unquote(runtime_key)
      runtimes = ["client", "server", "all", nil, :absent, "CLIENT", :client]

      flags =
        for {runtime, index} <- Enum.with_index(runtimes),
            reason <- [:experience_continuity, :unsupported_definition] do
          warning_flag("#{reason}-#{index}", reason)
          |> with_runtime(runtime_key, runtime)
        end

      local_flags = [
        %{
          "key" => "client-true",
          "active" => true,
          "filters" => %{"groups" => [%{"properties" => [], "rollout_percentage" => 100}]}
        },
        %{"key" => "client-false", "active" => false},
        %{
          "key" => "client-variant",
          "active" => true,
          "filters" => %{
            "groups" => [%{"properties" => [], "rollout_percentage" => 100}],
            "multivariate" => %{
              "variants" => [%{"key" => "blue", "rollout_percentage" => 100}]
            }
          }
        }
      ]

      flags = flags ++ Enum.map(local_flags, &with_runtime(&1, runtime_key, "client"))
      {agent, initial_log} = start_source(source, flags)

      expected =
        for {_runtime, index} <- Enum.with_index(runtimes),
            index != 0,
            reason <- [:experience_continuity, :unsupported_definition] do
          {"#{reason}-#{index}", to_string(reason)}
        end

      assert warnings(initial_log) == Enum.sort(expected)
      definitions = DefinitionLoader.definitions(instance())
      assert definitions.flags == flags

      expected_reasons =
        Map.new(Enum.take(flags, length(runtimes) * 2), fn flag ->
          reason =
            if flag["ensure_experience_continuity"],
              do: :experience_continuity,
              else: :unsupported_definition

          {flag["key"], reason}
        end)

      assert definitions.definition_reasons == expected_reasons

      assert {:ok, snapshot} =
               FeatureFlags.evaluate_flags(instance(), %{
                 distinct_id: "user",
                 only_evaluate_locally: true
               })

      assert snapshot.unresolved_flags == expected_reasons
      assert Evaluations.keys(snapshot) == ["client-false", "client-true", "client-variant"]
      assert Evaluations.get_flag(snapshot, "client-true") == true
      assert Evaluations.get_flag(snapshot, "client-false") == false
      assert Evaluations.get_flag(snapshot, "client-variant") == "blue"

      assert warnings(refresh(agent, envelope(flags))) == []
      reordered = Enum.map(Enum.reverse(flags), &(&1 |> Enum.reverse() |> Map.new()))
      assert warnings(refresh(agent, envelope(reordered))) == []

      assert warnings(not_modified_refresh(source, agent)) == []
      assert_requests(agent, source, 4)
    end

    for reason <- [:experience_continuity, :unsupported_definition],
        runtime <- ["server", "all", nil, :absent] do
      test "#{source} #{inspect(runtime_key)} #{reason} clears client history before returning to #{inspect(runtime)}" do
        source = unquote(source)
        runtime_key = unquote(runtime_key)
        reason = unquote(reason)
        runtime = unquote(runtime)
        original = warning_flag("checkout", reason) |> with_runtime(runtime_key, runtime)
        {agent, initial_log} = start_source(source, [original])
        expected = [{"checkout", to_string(reason)}]
        assert warnings(initial_log) == expected
        assert warnings(refresh(agent, envelope([original]))) == []

        client = with_runtime(original, runtime_key, "client")
        assert warnings(refresh(agent, envelope([client]))) == []
        loader = GenServer.whereis(PostHog.Registry.via(instance(), DefinitionLoader))
        assert :sys.get_state(loader).warned_unresolvable_flags == %{}

        assert DefinitionLoader.definitions(instance()).definition_reasons == %{
                 "checkout" => reason
               }

        assert DefinitionLoader.definitions(instance()).flags_by_key["checkout"] == client
        assert warnings(refresh(agent, envelope([client]))) == []

        # Restore the exact old definition and version, not just another nonclient definition.
        assert warnings(refresh(agent, envelope([original]))) == expected
        assert warnings(refresh(agent, envelope([original]))) == []
        assert_requests(agent, source, 6)
      end
    end
  end

  defp instance, do: __MODULE__.Warnings

  defp start_source(source, flags) do
    agent = start_supervised!({Agent, fn -> %{body: envelope(flags), requests: []} end})

    stub(PostHog.API.Mock, :client, fn _key, _host ->
      %PostHog.API.Client{client: :stub_client, module: PostHog.API.Mock}
    end)

    stub(PostHog.API.Mock, :request, fn _client, method, path, _opts ->
      Agent.get_and_update(agent, fn state ->
        {api_response(method, path, state.body),
         %{state | requests: state.requests ++ [{method, path}]}}
      end)
    end)

    overrides =
      if source == :cache,
        do: [secret_key: nil, flag_definition_cache_provider: {Provider, agent}],
        else: []

    config =
      [
        api_key: "project-token",
        secret_key: "secret-value",
        api_client_module: PostHog.API.Mock,
        supervisor_name: instance(),
        test_mode: true,
        feature_flags_poll_interval_ms: 60_000
      ]
      |> Keyword.merge(overrides)
      |> PostHog.Config.validate!()
      |> Map.put(:sender_pool_size, 1)

    log =
      capture_log(fn ->
        start_supervised!({PostHog.Supervisor, config})
        assert DefinitionLoader.ready?(instance())
      end)

    {agent, log}
  end

  defp api_response(:get, "/flags/definitions", :not_modified),
    do: {:ok, %{status: 304, body: nil, headers: %{}}}

  defp api_response(:get, "/flags/definitions", body),
    do: {:ok, %{status: 200, body: body, headers: %{"etag" => "v1"}}}

  defp api_response(_method, _path, _body), do: {:error, :unexpected_evaluation_request}

  defp refresh(agent, body) do
    Agent.update(agent, &%{&1 | body: body})
    capture_log(fn -> assert :ok = DefinitionLoader.refresh(instance()) end)
  end

  defp not_modified_refresh(:api, agent), do: refresh(agent, :not_modified)
  defp not_modified_refresh(:cache, _agent), do: ""

  defp assert_requests(agent, source, count) do
    expected =
      if source == :api, do: List.duplicate({:get, "/flags/definitions"}, count), else: []

    assert Agent.get(agent, & &1.requests) == expected
  end

  defp warnings(log) do
    ~r/feature flag "([^"]+)".*\(reason: (experience_continuity|unsupported_definition)\)/
    |> Regex.scan(log, capture: :all_but_first)
    |> Enum.map(&List.to_tuple/1)
    |> Enum.sort()
  end

  defp envelope(flags), do: %{"flags" => flags, "group_type_mapping" => %{}, "cohorts" => %{}}

  defp with_runtime(flag, _key, :absent), do: flag
  defp with_runtime(flag, key, runtime), do: Map.put(flag, key, runtime)

  defp warning_flag(key, :experience_continuity) do
    %{"key" => key, "version" => 1, "active" => true, "ensure_experience_continuity" => true}
  end

  defp warning_flag(key, :unsupported_definition) do
    %{
      "key" => key,
      "version" => 1,
      "active" => true,
      "filters" => %{
        "groups" => [%{"properties" => [%{"type" => "cohort", "value" => "static"}]}]
      }
    }
  end
end
