defmodule PostHog.FeatureFlags.EvaluationsTest do
  use PostHog.Case,
    async: Version.match?(System.version(), ">= 1.18.0"),
    group: PostHog

  @moduletag config: [supervisor_name: PostHog]

  import Mox

  alias PostHog.API
  alias PostHog.FeatureFlags
  alias PostHog.FeatureFlags.Evaluations
  alias PostHog.FeatureFlags.Result

  setup :setup_supervisor
  setup :verify_on_exit!

  defp stub_flags_response do
    %{
      status: 200,
      body: %{
        "flags" => %{
          "boolean-flag" => %{
            "enabled" => true,
            "key" => "boolean-flag",
            "variant" => nil,
            "metadata" => %{"id" => 1, "version" => 2, "payload" => nil},
            "reason" => %{"code" => "condition_match", "description" => "matched"}
          },
          "variant-flag" => %{
            "enabled" => true,
            "key" => "variant-flag",
            "variant" => "control",
            "metadata" => %{"id" => 2, "version" => 5, "payload" => %{"copy" => "hi"}},
            "reason" => %{"code" => "condition_match", "description" => "matched"}
          },
          "disabled-flag" => %{
            "enabled" => false,
            "key" => "disabled-flag",
            "variant" => nil,
            "metadata" => %{"id" => 3, "version" => 1, "payload" => nil},
            "reason" => %{"code" => "no_condition_match", "description" => "did not match"}
          }
        },
        "requestId" => "req-abc",
        "evaluatedAt" => 1_700_000_000
      }
    }
  end

  describe "evaluate_flags/2" do
    test "returns a snapshot containing every evaluated flag" do
      expect(API.Mock, :request, fn _client, :post, "/flags", _opts ->
        {:ok, stub_flags_response()}
      end)

      assert {:ok, %Evaluations{distinct_id: "foo"} = snapshot} =
               FeatureFlags.evaluate_flags("foo")

      assert Evaluations.keys(snapshot) == ["boolean-flag", "disabled-flag", "variant-flag"]
      assert snapshot.request_id == "req-abc"
      assert snapshot.evaluated_at == 1_700_000_000
    end

    test "makes exactly one /flags request" do
      expect(API.Mock, :request, 1, fn _client, :post, "/flags", _opts ->
        {:ok, stub_flags_response()}
      end)

      assert {:ok, _} = FeatureFlags.evaluate_flags("foo")
    end

    test "does not fire any $feature_flag_called events on construction" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, stub_flags_response()}
      end)

      assert {:ok, _} = FeatureFlags.evaluate_flags("foo")
      assert all_captured() == []
    end

    test "translates :flag_keys into flag_keys_to_evaluate in the request body" do
      expect(API.Mock, :request, fn _client, :post, "/flags", opts ->
        assert opts[:json] == %{
                 distinct_id: "foo",
                 flag_keys_to_evaluate: ["boolean-flag", "variant-flag"]
               }

        {:ok, stub_flags_response()}
      end)

      assert {:ok, _} =
               FeatureFlags.evaluate_flags(%{
                 distinct_id: "foo",
                 flag_keys: ["boolean-flag", "variant-flag"]
               })
    end

    test "forwards person_properties unchanged in the request body" do
      expect(API.Mock, :request, fn _client, :post, "/flags", opts ->
        assert opts[:json] == %{distinct_id: "foo", person_properties: %{plan: "enterprise"}}
        {:ok, stub_flags_response()}
      end)

      assert {:ok, _} =
               FeatureFlags.evaluate_flags(%{
                 distinct_id: "foo",
                 person_properties: %{plan: "enterprise"}
               })
    end

    test "reads distinct_id from context when none is provided" do
      PostHog.set_context(%{distinct_id: "from-context"})

      expect(API.Mock, :request, fn _client, :post, "/flags", opts ->
        assert opts[:json] == %{distinct_id: "from-context"}
        {:ok, stub_flags_response()}
      end)

      assert {:ok, %Evaluations{distinct_id: "from-context"}} = FeatureFlags.evaluate_flags()
    end

    test "returns an error when distinct_id cannot be resolved" do
      assert {:error, %PostHog.Error{}} = FeatureFlags.evaluate_flags(nil)
      assert all_captured() == []
    end

    @tag config: [supervisor_name: MyPostHog]
    test "supports a named PostHog instance" do
      expect(API.Mock, :request, fn _client, :post, "/flags", _opts ->
        {:ok, stub_flags_response()}
      end)

      assert {:ok, %Evaluations{supervisor_name: MyPostHog}} =
               FeatureFlags.evaluate_flags(MyPostHog, "foo")
    end
  end

  describe "enabled?/2 and get_flag/2" do
    setup do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, stub_flags_response()}
      end)

      {:ok, snapshot} = FeatureFlags.evaluate_flags("foo")
      %{snapshot: snapshot}
    end

    test "enabled?/2 returns the boolean for known flags", %{snapshot: snapshot} do
      assert Evaluations.enabled?(snapshot, "boolean-flag") == true
      assert Evaluations.enabled?(snapshot, "variant-flag") == true
      assert Evaluations.enabled?(snapshot, "disabled-flag") == false
    end

    test "enabled?/2 returns false for unknown flags and fires a flag_missing event",
         %{snapshot: snapshot} do
      assert Evaluations.enabled?(snapshot, "unknown-flag") == false

      assert [
               %{
                 event: "$feature_flag_called",
                 distinct_id: "foo",
                 properties: %{
                   "$feature_flag": "unknown-flag",
                   "$feature_flag_response": false,
                   "$feature_flag_error": "flag_missing"
                 }
               }
             ] = all_captured()
    end

    test "get_flag/2 returns the variant when present", %{snapshot: snapshot} do
      assert Evaluations.get_flag(snapshot, "variant-flag") == "control"
    end

    test "get_flag/2 returns true/false for boolean flags", %{snapshot: snapshot} do
      assert Evaluations.get_flag(snapshot, "boolean-flag") == true
      assert Evaluations.get_flag(snapshot, "disabled-flag") == false
    end

    test "get_flag/2 returns nil for unknown flags and fires a flag_missing event",
         %{snapshot: snapshot} do
      assert Evaluations.get_flag(snapshot, "unknown-flag") == nil

      assert [
               %{
                 event: "$feature_flag_called",
                 distinct_id: "foo",
                 properties: %{
                   "$feature_flag": "unknown-flag",
                   "$feature_flag_response": false,
                   "$feature_flag_error": "flag_missing"
                 }
               }
             ] = all_captured()
    end

    test "fires $feature_flag_called with full metadata", %{snapshot: snapshot} do
      assert Evaluations.get_flag(snapshot, "variant-flag") == "control"

      assert [
               %{
                 event: "$feature_flag_called",
                 distinct_id: "foo",
                 properties: %{
                   "$feature_flag": "variant-flag",
                   "$feature_flag_response": "control",
                   "$feature_flag_id": 2,
                   "$feature_flag_version": 5,
                   "$feature_flag_reason": %{"code" => "condition_match"},
                   "$feature_flag_request_id": "req-abc",
                   "$feature_flag_evaluated_at": 1_700_000_000
                 }
               }
             ] = all_captured()
    end

    test "fires on every access (no dedup in this PR)", %{snapshot: snapshot} do
      Evaluations.enabled?(snapshot, "boolean-flag")
      Evaluations.enabled?(snapshot, "boolean-flag")
      Evaluations.get_flag(snapshot, "boolean-flag")

      assert length(all_captured()) == 3
    end
  end

  describe "get_flag_payload/2" do
    setup do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, stub_flags_response()}
      end)

      {:ok, snapshot} = FeatureFlags.evaluate_flags("foo")
      %{snapshot: snapshot}
    end

    test "returns the configured payload", %{snapshot: snapshot} do
      assert Evaluations.get_flag_payload(snapshot, "variant-flag") == %{"copy" => "hi"}
    end

    test "returns nil when no payload is configured", %{snapshot: snapshot} do
      assert Evaluations.get_flag_payload(snapshot, "boolean-flag") == nil
    end

    test "returns nil for unknown flags", %{snapshot: snapshot} do
      assert Evaluations.get_flag_payload(snapshot, "unknown-flag") == nil
    end

    test "does not fire a $feature_flag_called event", %{snapshot: snapshot} do
      Evaluations.get_flag_payload(snapshot, "variant-flag")
      Evaluations.get_flag_payload(snapshot, "unknown-flag")

      assert all_captured() == []
    end
  end

  describe "only/2" do
    setup do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, stub_flags_response()}
      end)

      {:ok, snapshot} = FeatureFlags.evaluate_flags("foo")
      %{snapshot: snapshot}
    end

    test "narrows the snapshot to the requested keys", %{snapshot: snapshot} do
      narrowed = Evaluations.only(snapshot, ["boolean-flag", "variant-flag"])
      assert Evaluations.keys(narrowed) == ["boolean-flag", "variant-flag"]
    end

    test "silently drops unknown keys", %{snapshot: snapshot} do
      narrowed = Evaluations.only(snapshot, ["boolean-flag", "does-not-exist"])
      assert Evaluations.keys(narrowed) == ["boolean-flag"]
    end

    test "preserves snapshot metadata", %{snapshot: snapshot} do
      narrowed = Evaluations.only(snapshot, ["boolean-flag"])

      assert narrowed.distinct_id == snapshot.distinct_id
      assert narrowed.supervisor_name == snapshot.supervisor_name
      assert narrowed.request_id == snapshot.request_id
      assert narrowed.evaluated_at == snapshot.evaluated_at
    end
  end

  describe "event_properties/1" do
    setup do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, stub_flags_response()}
      end)

      {:ok, snapshot} = FeatureFlags.evaluate_flags("foo")
      %{snapshot: snapshot}
    end

    test "produces $feature/<key> entries for every flag", %{snapshot: snapshot} do
      properties = Evaluations.event_properties(snapshot)

      assert properties["$feature/boolean-flag"] == true
      assert properties["$feature/variant-flag"] == "control"
      assert properties["$feature/disabled-flag"] == false
    end

    test "produces $active_feature_flags sorted, enabled-only", %{snapshot: snapshot} do
      properties = Evaluations.event_properties(snapshot)

      assert properties[:"$active_feature_flags"] == ["boolean-flag", "variant-flag"]
    end

    test "omits $active_feature_flags when no flag is enabled" do
      snapshot = %Evaluations{
        supervisor_name: PostHog,
        distinct_id: "foo",
        flags: %{
          "off" => %Result{key: "off", enabled: false}
        }
      }

      properties = Evaluations.event_properties(snapshot)

      refute Map.has_key?(properties, :"$active_feature_flags")
      assert properties["$feature/off"] == false
    end
  end

  describe "set_in_context/2" do
    test "merges $feature/<key> and $active_feature_flags into the context" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, stub_flags_response()}
      end)

      {:ok, snapshot} = FeatureFlags.evaluate_flags("foo")
      :ok = FeatureFlags.set_in_context(snapshot)

      context = PostHog.get_context()
      assert context["$feature/boolean-flag"] == true
      assert context["$feature/variant-flag"] == "control"
      assert context["$feature/disabled-flag"] == false
      assert context[:"$active_feature_flags"] == ["boolean-flag", "variant-flag"]
    end

    test "captures triggered after set_in_context attach the snapshot's properties" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, stub_flags_response()}
      end)

      {:ok, snapshot} = FeatureFlags.evaluate_flags("foo")
      :ok = FeatureFlags.set_in_context(snapshot)

      :ok = PostHog.capture("page_viewed", %{distinct_id: "foo"})

      assert [
               %{
                 event: "page_viewed",
                 distinct_id: "foo",
                 properties: properties
               }
             ] = all_captured()

      assert properties["$feature/boolean-flag"] == true
      assert properties["$feature/variant-flag"] == "control"
      assert properties[:"$active_feature_flags"] == ["boolean-flag", "variant-flag"]
    end

    test "does not trigger an additional /flags request when capturing" do
      expect(API.Mock, :request, 1, fn _client, _method, _url, _opts ->
        {:ok, stub_flags_response()}
      end)

      {:ok, snapshot} = FeatureFlags.evaluate_flags("foo")
      :ok = FeatureFlags.set_in_context(snapshot)
      :ok = PostHog.capture("page_viewed", %{distinct_id: "foo"})
    end
  end

  describe "errors_while_computing propagation" do
    defp errored_flags_response do
      response = stub_flags_response()
      put_in(response, [:body, "errorsWhileComputingFlags"], true)
    end

    test "attaches errors_while_computing_flags to events for known flags" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, errored_flags_response()}
      end)

      {:ok, snapshot} = FeatureFlags.evaluate_flags("foo")
      assert snapshot.errors_while_computing == true
      Evaluations.enabled?(snapshot, "boolean-flag")

      assert [
               %{
                 event: "$feature_flag_called",
                 properties: %{
                   "$feature_flag": "boolean-flag",
                   "$feature_flag_error": "errors_while_computing_flags"
                 }
               }
             ] = all_captured()
    end

    test "combines errors_while_computing_flags with flag_missing for missing flags" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, errored_flags_response()}
      end)

      {:ok, snapshot} = FeatureFlags.evaluate_flags("foo")
      Evaluations.enabled?(snapshot, "missing-flag")

      assert [
               %{
                 event: "$feature_flag_called",
                 properties: %{
                   "$feature_flag": "missing-flag",
                   "$feature_flag_error": "errors_while_computing_flags,flag_missing"
                 }
               }
             ] = all_captured()
    end

    test "omits $feature_flag_error when there are no errors", %{} do
      # uses the default stub_flags_response with errorsWhileComputingFlags absent
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, stub_flags_response()}
      end)

      {:ok, snapshot} = FeatureFlags.evaluate_flags("foo")
      Evaluations.enabled?(snapshot, "boolean-flag")

      assert [%{properties: properties}] = all_captured()
      refute Map.has_key?(properties, :"$feature_flag_error")
    end
  end

  describe "empty distinct_id" do
    test "manually-constructed snapshot with empty distinct_id does not fire events" do
      snapshot = %Evaluations{
        supervisor_name: PostHog,
        distinct_id: "",
        flags: %{
          "flag" => %Result{key: "flag", enabled: true}
        }
      }

      Evaluations.enabled?(snapshot, "flag")
      Evaluations.get_flag(snapshot, "flag")

      assert all_captured() == []
    end
  end
end
