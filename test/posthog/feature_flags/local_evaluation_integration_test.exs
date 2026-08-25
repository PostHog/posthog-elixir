defmodule PostHog.FeatureFlags.LocalEvaluationIntegrationTest do
  use ExUnit.Case, async: false
  import Mox

  alias PostHog.FeatureFlags
  alias PostHog.FeatureFlags.Evaluations

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    stub(PostHog.API.Mock, :client, fn _api_key, _host ->
      %PostHog.API.Client{client: :stub_client, module: PostHog.API.Mock}
    end)

    :ok
  end

  defp flag(key, properties \\ [], extra \\ %{}) do
    Map.merge(
      %{
        "id" => 11,
        "version" => 3,
        "key" => key,
        "active" => true,
        "filters" => %{
          "groups" => [%{"properties" => properties, "rollout_percentage" => 100}]
        }
      },
      extra
    )
  end

  defp envelope(flags) do
    %{"flags" => flags, "group_type_mapping" => %{"0" => "organization"}, "cohorts" => %{}}
  end

  defp start_instance(name) do
    config =
      PostHog.Config.validate!(
        api_key: "token",
        secret_key: "secret",
        api_client_module: PostHog.API.Mock,
        supervisor_name: name,
        test_mode: true,
        feature_flags_poll_interval_ms: 60_000
      )
      |> Map.put(:sender_pool_size, 1)

    start_supervised!({PostHog.Supervisor, config})
  end

  test "matching local boolean and variant payload produce a frozen snapshot without /flags" do
    variant =
      flag("variant", [], %{
        "filters" => %{
          "groups" => [%{"properties" => [], "rollout_percentage" => 100, "variant" => "test"}],
          "multivariate" => %{"variants" => [%{"key" => "test", "rollout_percentage" => 100}]},
          "payloads" => %{"test" => ~s({"answer":42})}
        }
      })

    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 200, body: envelope([flag("boolean"), variant]), headers: %{}}}
    end)

    start_instance(__MODULE__.Local)
    assert {:ok, snapshot} = FeatureFlags.evaluate_flags(__MODULE__.Local, "user")
    assert PostHog.Test.all_captured(__MODULE__.Local) == []
    assert Evaluations.keys(snapshot) == ["boolean", "variant"]
    assert snapshot.flags["boolean"].enabled
    assert snapshot.flags["variant"].variant == "test"
    assert Evaluations.get_flag_payload(snapshot, "variant") == %{"answer" => 42}

    assert Evaluations.get_flag(snapshot, "boolean")
    assert PostHog.get_context(__MODULE__.Local)["$feature/boolean"] == true
    assert [event] = PostHog.Test.all_captured(__MODULE__.Local)
    assert event.event == "$feature_flag_called"
    assert event.properties[:"$feature_flag_id"] == 11
    assert event.properties[:"$feature_flag_version"] == 3
  end

  test "unknown and missing properties fall back once and local results win merge conflicts" do
    unknown = flag("unknown", [%{"key" => "x", "operator" => "future", "value" => 1}])

    expect(PostHog.API.Mock, :request, 2, fn
      :stub_client, :get, "/flags/definitions", _opts ->
        {:ok, %{status: 200, body: envelope([flag("local"), unknown]), headers: %{}}}

      :stub_client, :post, "/flags", opts ->
        send(self(), {:remote_body, opts[:json]})

        {:ok,
         %{
           status: 200,
           body: %{
             "flags" => %{
               "local" => %{"enabled" => false},
               "unknown" => %{"enabled" => true},
               "extra" => %{"enabled" => true}
             }
           }
         }}
    end)

    start_instance(__MODULE__.Merge)

    assert {:ok, snapshot} =
             FeatureFlags.evaluate_flags(__MODULE__.Merge, %{
               distinct_id: "user",
               person_properties: %{x: 1}
             })

    assert snapshot.flags["local"].enabled
    assert snapshot.flags["unknown"].enabled
    assert snapshot.flags["extra"].enabled
  end

  test "explicit scope is preserved and local-only returns partial results with no request" do
    missing_property = flag("needs-server", [%{"key" => "plan", "value" => "pro"}])

    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 200, body: envelope([flag("local"), missing_property]), headers: %{}}}
    end)

    start_instance(__MODULE__.LocalOnly)

    assert {:ok, snapshot} =
             FeatureFlags.evaluate_flags(__MODULE__.LocalOnly, %{
               distinct_id: "user",
               flag_keys: ["local", "needs-server", "missing"],
               only_evaluate_locally: true
             })

    assert Evaluations.keys(snapshot) == ["local"]
  end

  test "remote failure preserves a partial local snapshot" do
    unknown = flag("unknown", [%{"key" => "x", "operator" => "future", "value" => 1}])

    expect(PostHog.API.Mock, :request, 2, fn
      :stub_client, :get, "/flags/definitions", _opts ->
        {:ok, %{status: 200, body: envelope([flag("local"), unknown]), headers: %{}}}

      :stub_client, :post, "/flags", _opts ->
        {:error, %RuntimeError{message: "offline"}}
    end)

    start_instance(__MODULE__.Partial)
    assert {:ok, snapshot} = FeatureFlags.evaluate_flags(__MODULE__.Partial, "user")
    assert Evaluations.keys(snapshot) == ["local"]
  end

  test "malformed remote fallback preserves a partial local snapshot" do
    unknown = flag("unknown", [%{"key" => "x", "operator" => "future", "value" => 1}])

    expect(PostHog.API.Mock, :request, 2, fn
      :stub_client, :get, "/flags/definitions", _opts ->
        {:ok, %{status: 200, body: envelope([flag("local"), unknown]), headers: %{}}}

      :stub_client, :post, "/flags", _opts ->
        {:ok, %{status: 200, body: %{"flags" => ["malformed"]}}}
    end)

    start_instance(__MODULE__.MalformedFallback)
    assert {:ok, snapshot} = FeatureFlags.evaluate_flags(__MODULE__.MalformedFallback, "user")
    assert Evaluations.keys(snapshot) == ["local"]
  end

  test "malformed remote fallback returns an error when nothing resolved locally" do
    unknown = flag("unknown", [%{"key" => "x", "operator" => "future", "value" => 1}])

    expect(PostHog.API.Mock, :request, 2, fn
      :stub_client, :get, "/flags/definitions", _opts ->
        {:ok, %{status: 200, body: envelope([unknown]), headers: %{}}}

      :stub_client, :post, "/flags", _opts ->
        {:ok, %{status: 200, body: %{"flags" => ["malformed"]}}}
    end)

    start_instance(__MODULE__.MalformedOnly)

    assert {:error, %RuntimeError{message: "invalid response from PostHog /flags endpoint"}} =
             FeatureFlags.evaluate_flags(__MODULE__.MalformedOnly, "user")
  end

  test "group absence makes only that flag fall back and requested missing keys are remotely scoped" do
    group = put_in(flag("group"), ["filters", "aggregation_group_type_index"], 0)
    caller = self()

    expect(PostHog.API.Mock, :request, 2, fn
      :stub_client, :get, "/flags/definitions", _opts ->
        {:ok, %{status: 200, body: envelope([group]), headers: %{}}}

      :stub_client, :post, "/flags", opts ->
        send(caller, {:body, opts[:json]})

        {:ok,
         %{
           status: 200,
           body: %{
             "flags" => %{
               "group" => %{"enabled" => false},
               "unrequested" => %{"enabled" => true}
             }
           }
         }}
    end)

    start_instance(__MODULE__.Group)

    assert {:ok, snapshot} =
             FeatureFlags.evaluate_flags(__MODULE__.Group, %{
               distinct_id: "user",
               flag_keys: ["group", "missing"]
             })

    assert_receive {:body, %{flag_keys_to_evaluate: ["group", "missing"]}}
    refute snapshot.flags["group"].enabled
    refute snapshot.flags["unrequested"]
  end

  test "a requested key missing only from local definitions falls back exactly once" do
    owner = self()

    expect(PostHog.API.Mock, :request, 2, fn
      :stub_client, :get, "/flags/definitions", _opts ->
        {:ok, %{status: 200, body: envelope([flag("local")]), headers: %{}}}

      :stub_client, :post, "/flags", opts ->
        send(owner, {:missing_fallback, opts[:json]})
        {:ok, %{status: 200, body: %{"flags" => %{"missing" => %{"enabled" => true}}}}}
    end)

    start_instance(__MODULE__.Missing)

    assert {:ok, snapshot} =
             FeatureFlags.evaluate_flags(__MODULE__.Missing, %{
               distinct_id: "user",
               flag_keys: ["missing"]
             })

    assert_receive {:missing_fallback, %{flag_keys_to_evaluate: ["missing"]}}
    assert snapshot.flags["missing"].enabled
  end

  test "deprecated getters evaluate dependencies locally and preserve local missing/send_event contracts" do
    base = flag("base")

    dependency = %{
      "type" => "flag",
      "key" => "base",
      "operator" => "flag_evaluates_to",
      "value" => true,
      "dependency_chain" => ["base"]
    }

    expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
      {:ok, %{status: 200, body: envelope([base, flag("dependent", [dependency])]), headers: %{}}}
    end)

    start_instance(__MODULE__.Dependencies)
    assert {:ok, true} = FeatureFlags.check(__MODULE__.Dependencies, "dependent", "user")

    before_context = PostHog.get_context(__MODULE__.Dependencies)
    captured_count = length(PostHog.Test.all_captured(__MODULE__.Dependencies))

    assert {:ok, %{enabled: true}} =
             FeatureFlags.get_feature_flag_result(
               __MODULE__.Dependencies,
               "dependent",
               "user",
               send_event: false
             )

    assert length(PostHog.Test.all_captured(__MODULE__.Dependencies)) == captured_count
    assert PostHog.get_context(__MODULE__.Dependencies) == before_context

    assert {:ok, nil} =
             FeatureFlags.get_feature_flag_result(
               __MODULE__.Dependencies,
               "missing",
               %{distinct_id: "user", only_evaluate_locally: true},
               send_event: false
             )

    assert {:error, %PostHog.UnexpectedResponseError{}} =
             FeatureFlags.check(
               __MODULE__.Dependencies,
               "missing",
               %{distinct_id: "user", only_evaluate_locally: true}
             )
  end

  test "snapshots stay frozen across refresh and named context plus deprecated API use local results" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    expect(PostHog.API.Mock, :request, 2, fn :stub_client, :get, "/flags/definitions", _opts ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 ->
          {:ok, %{status: 200, body: envelope([flag("named")]), headers: %{}}}

        1 ->
          {:ok,
           %{status: 200, body: envelope([%{flag("named") | "active" => false}]), headers: %{}}}
      end
    end)

    start_instance(__MODULE__.Named)
    PostHog.set_context(__MODULE__.Named, %{distinct_id: "named-user"})

    assert {:ok, old} = FeatureFlags.evaluate_flags(__MODULE__.Named, nil)
    assert old.flags["named"].enabled
    assert {:ok, true} = FeatureFlags.check(__MODULE__.Named, "named", nil)

    assert {:ok, %{enabled: true}} =
             FeatureFlags.get_feature_flag_result(__MODULE__.Named, "named", nil,
               send_event: false
             )

    FeatureFlags.DefinitionLoader.refresh(__MODULE__.Named)
    assert old.flags["named"].enabled
    assert {:ok, new} = FeatureFlags.evaluate_flags(__MODULE__.Named, nil)
    refute new.flags["named"].enabled
  end
end
