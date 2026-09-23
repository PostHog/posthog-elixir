defmodule PostHog.OpenFeature.ProviderTest do
  use PostHog.Case, async: false, group: PostHog

  @moduletag config: [supervisor_name: PostHog]

  import Mox

  alias OpenFeature.ResolutionDetails
  alias PostHog.API
  alias PostHog.OpenFeature.Provider

  setup :setup_supervisor
  setup :verify_on_exit!

  @context %{"targeting_key" => "user-1"}

  defp flag(attrs) do
    Map.merge(%{"enabled" => true, "variant" => nil, "metadata" => %{"payload" => nil}}, attrs)
  end

  defp expect_flags(flags) do
    expect(API.Mock, :request, fn _client, :post, "/flags", _opts ->
      {:ok, %{status: 200, body: %{"flags" => flags}}}
    end)
  end

  defp expect_flag(key, attrs), do: expect_flags(%{key => flag(Map.put(attrs, "key", key))})

  defp provider(opts \\ []) do
    {:ok, provider} = Provider.initialize(struct(Provider, opts), "default", %{})
    provider
  end

  describe "initialize/3" do
    test "marks the provider ready and keeps the domain" do
      assert {:ok, %Provider{state: :ready, domain: "my-domain", name: "PostHogProvider"}} =
               Provider.initialize(%Provider{}, "my-domain", %{})
    end
  end

  describe "resolve_boolean_value/4" do
    test "resolves an enabled flag" do
      expect_flag("flag", %{"enabled" => true})

      assert {:ok, %ResolutionDetails{value: true, reason: :targeting_match, variant: nil}} =
               Provider.resolve_boolean_value(provider(), "flag", false, @context)
    end

    test "resolves a disabled flag" do
      expect_flag("flag", %{"enabled" => false})

      assert {:ok, %ResolutionDetails{value: false, reason: :default}} =
               Provider.resolve_boolean_value(provider(), "flag", true, @context)
    end

    test "includes the variant for multivariate flags" do
      expect_flag("flag", %{"variant" => "test"})

      assert {:ok, %ResolutionDetails{value: true, variant: "test"}} =
               Provider.resolve_boolean_value(provider(), "flag", false, @context)
    end
  end

  describe "resolve_string_value/4" do
    test "resolves the variant" do
      expect_flag("flag", %{"variant" => "test"})

      assert {:ok, %ResolutionDetails{value: "test", variant: "test", reason: :targeting_match}} =
               Provider.resolve_string_value(provider(), "flag", "control", @context)
    end

    test "returns the default for a disabled flag without a variant" do
      expect_flag("flag", %{"enabled" => false})

      assert {:ok, %ResolutionDetails{value: "control", reason: :default, error_code: nil}} =
               Provider.resolve_string_value(provider(), "flag", "control", @context)
    end

    test "returns type_mismatch for an enabled flag without a variant" do
      expect_flag("flag", %{"enabled" => true})

      assert {:ok,
              %ResolutionDetails{value: "control", reason: :error, error_code: :type_mismatch}} =
               Provider.resolve_string_value(provider(), "flag", "control", @context)
    end
  end

  describe "resolve_number_value/4" do
    for {variant, expected} <- [{"42", 42}, {"3.5", 3.5}, {" 7 ", 7}, {"-1", -1}] do
      test "parses variant #{inspect(variant)}" do
        expect_flag("flag", %{"variant" => unquote(variant)})

        assert {:ok, %ResolutionDetails{value: value, reason: :targeting_match}} =
                 Provider.resolve_number_value(provider(), "flag", 0, @context)

        assert value === unquote(expected)
      end
    end

    for variant <- ["abc", "", "  ", "12abc"] do
      test "returns type_mismatch for variant #{inspect(variant)}" do
        expect_flag("flag", %{"variant" => unquote(variant)})

        assert {:ok, %ResolutionDetails{value: 0, reason: :error, error_code: :type_mismatch}} =
                 Provider.resolve_number_value(provider(), "flag", 0, @context)
      end
    end

    test "returns the default for a disabled flag without a variant" do
      expect_flag("flag", %{"enabled" => false})

      assert {:ok, %ResolutionDetails{value: 5, reason: :default}} =
               Provider.resolve_number_value(provider(), "flag", 5, @context)
    end

    test "returns type_mismatch for an enabled flag without a variant" do
      expect_flag("flag", %{"enabled" => true})

      assert {:ok, %ResolutionDetails{value: 5, error_code: :type_mismatch}} =
               Provider.resolve_number_value(provider(), "flag", 5, @context)
    end
  end

  describe "resolve_map_value/4" do
    test "resolves the payload" do
      expect_flag("flag", %{"variant" => "test", "metadata" => %{"payload" => ~s({"a": 1})}})

      assert {:ok, %ResolutionDetails{value: %{"a" => 1}, variant: "test"}} =
               Provider.resolve_map_value(provider(), "flag", %{}, @context)
    end

    test "returns the default for a disabled flag without a payload" do
      expect_flag("flag", %{"enabled" => false})

      assert {:ok, %ResolutionDetails{value: %{"d" => 1}, reason: :default}} =
               Provider.resolve_map_value(provider(), "flag", %{"d" => 1}, @context)
    end

    test "returns type_mismatch for an enabled flag without a payload" do
      expect_flag("flag", %{"enabled" => true})

      assert {:ok, %ResolutionDetails{value: %{}, error_code: :type_mismatch}} =
               Provider.resolve_map_value(provider(), "flag", %{}, @context)
    end

    test "returns type_mismatch for a non-object payload" do
      expect_flag("flag", %{"metadata" => %{"payload" => "[1, 2]"}})

      assert {:ok, %ResolutionDetails{value: %{}, error_code: :type_mismatch}} =
               Provider.resolve_map_value(provider(), "flag", %{}, @context)
    end
  end

  describe "errors" do
    test "returns flag_not_found when the flag is not in the response" do
      expect_flags(%{})

      assert {:error, :flag_not_found} =
               Provider.resolve_boolean_value(provider(), "flag", false, @context)
    end

    test "returns unexpected_error when the request fails" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:error, :transport_error}
      end)

      assert {:error, :unexpected_error, %PostHog.Error{}} =
               Provider.resolve_boolean_value(provider(), "flag", false, @context)
    end
  end

  describe "distinct ID" do
    for context <- [%{"targeting_key" => "user-1"}, %{targeting_key: "user-1"}] do
      test "uses targeting_key from #{inspect(context)}" do
        expect(API.Mock, :request, fn _client, :post, "/flags", opts ->
          assert opts[:json].distinct_id == "user-1"
          {:ok, %{status: 200, body: %{"flags" => %{"flag" => flag(%{})}}}}
        end)

        assert {:ok, _} =
                 Provider.resolve_boolean_value(
                   provider(),
                   "flag",
                   false,
                   unquote(Macro.escape(context))
                 )
      end
    end

    test "falls back to default_distinct_id" do
      expect(API.Mock, :request, fn _client, :post, "/flags", opts ->
        assert opts[:json].distinct_id == "fallback"
        {:ok, %{status: 200, body: %{"flags" => %{"flag" => flag(%{})}}}}
      end)

      assert {:ok, %ResolutionDetails{value: true}} =
               Provider.resolve_boolean_value(
                 provider(default_distinct_id: "fallback"),
                 "flag",
                 false,
                 %{}
               )
    end

    test "returns targeting_key_missing without targeting_key or default_distinct_id" do
      expect(API.Mock, :request, 0, fn _client, _method, _url, _opts -> :unreachable end)

      assert {:ok,
              %ResolutionDetails{
                value: false,
                reason: :error,
                error_code: :targeting_key_missing
              }} = Provider.resolve_boolean_value(provider(), "flag", false, %{})
    end
  end

  describe "context mapping" do
    test "forwards person properties, groups, and group properties without coercion" do
      expect(API.Mock, :request, fn _client, :post, "/flags", opts ->
        assert opts[:json] == %{
                 distinct_id: "user-1",
                 flag_keys_to_evaluate: ["flag"],
                 person_properties: %{"plan" => "pro", "age" => 30, "beta" => true},
                 groups: %{"company" => "acme"},
                 group_properties: %{"company" => %{"size" => 250}}
               }

        {:ok, %{status: 200, body: %{"flags" => %{"flag" => flag(%{})}}}}
      end)

      context = %{
        "targeting_key" => "user-1",
        "plan" => "pro",
        :age => 30,
        "beta" => true,
        "groups" => %{"company" => "acme"},
        :group_properties => %{"company" => %{"size" => 250}}
      }

      assert {:ok, _} = Provider.resolve_boolean_value(provider(), "flag", false, context)
    end

    test "omits empty person properties, groups, and group properties" do
      expect(API.Mock, :request, fn _client, :post, "/flags", opts ->
        assert opts[:json] == %{distinct_id: "user-1", flag_keys_to_evaluate: ["flag"]}
        {:ok, %{status: 200, body: %{"flags" => %{"flag" => flag(%{})}}}}
      end)

      context = %{"targeting_key" => "user-1", "groups" => %{}, "group_properties" => %{}}
      assert {:ok, _} = Provider.resolve_boolean_value(provider(), "flag", false, context)
    end
  end

  describe "send_feature_flag_events" do
    test "fires $feature_flag_called by default" do
      expect_flag("flag", %{})

      assert {:ok, _} = Provider.resolve_boolean_value(provider(), "flag", false, @context)

      assert [
               %{
                 event: "$feature_flag_called",
                 distinct_id: "user-1",
                 properties: %{"$feature_flag": "flag", "$feature_flag_response": true}
               }
             ] = all_captured()
    end

    test "does not fire events when disabled" do
      expect_flag("flag", %{})

      assert {:ok, _} =
               Provider.resolve_boolean_value(
                 provider(send_feature_flag_events: false),
                 "flag",
                 false,
                 @context
               )

      assert all_captured() == []
    end
  end

  describe "with the OpenFeature client" do
    setup do
      OpenFeature.clear_providers()
      {:ok, _} = OpenFeature.set_provider(%Provider{})
      on_exit(&OpenFeature.clear_providers/0)
      %{client: OpenFeature.get_client()}
    end

    test "resolves values", %{client: client} do
      expect_flag("flag", %{"variant" => "test"})

      assert OpenFeature.Client.get_string_value(client, "flag", "control", context: @context) ==
               "test"
    end

    test "surfaces type_mismatch", %{client: client} do
      expect_flag("flag", %{"enabled" => true})

      assert %{value: "control", reason: :error, error_code: :type_mismatch} =
               OpenFeature.Client.get_string_details(client, "flag", "control", context: @context)
    end

    test "surfaces flag_not_found", %{client: client} do
      expect_flags(%{})

      assert %{value: false, reason: :error, error_code: :flag_not_found} =
               OpenFeature.Client.get_boolean_details(client, "flag", false, context: @context)
    end
  end
end
