defmodule PosthogTest do
  use ExUnit.Case, async: true
  import Mimic

  setup do
    # Clear the cache before each test
    Cachex.clear(Posthog.Application.cache_name())
    stub_with(:hackney, HackneyStub)
    {:ok, _} = HackneyStub.State.start_link([])
    :ok
  end

  describe "feature_flag_enabled?/3" do
    test "true if the feature flag is enabled" do
      stub_with(:hackney, HackneyStub)

      HackneyStub.verify_capture(fn decoded ->
        assert decoded["event"] == "$feature_flag_called"
        assert decoded["distinct_id"] == "user_123"
        assert decoded["properties"]["$feature_flag"] == "my-awesome-flag"
        assert decoded["properties"]["$feature_flag_response"] == true
      end)

      assert Posthog.feature_flag_enabled?("my-awesome-flag", "user_123")
    end

    test "false if the feature flag is disabled" do
      stub_with(:hackney, HackneyStub)

      refute Posthog.feature_flag_enabled?("flag-thats-not-on", "user_123")
    end

    test "false if the feature flag does not exist" do
      stub_with(:hackney, HackneyStub)

      refute Posthog.feature_flag_enabled?("flag-does-not-exist", "user_123")
    end
  end

  describe "v3 - feature_flag/3" do
    test "when feature flag exists, returns feature flag struct" do
      stub_with(:hackney, HackneyStubV3)

      assert Posthog.feature_flag("my-awesome-flag", "user_123") ==
               {:ok,
                %Posthog.FeatureFlag{
                  enabled: true,
                  name: "my-awesome-flag",
                  payload: "example-payload-string"
                }}
    end

    test "when feature flag has a json payload, will return decoded payload" do
      stub_with(:hackney, HackneyStubV3)

      assert Posthog.feature_flag("my-awesome-flag-2", "user_123") ==
               {:ok,
                %Posthog.FeatureFlag{
                  enabled: true,
                  name: "my-awesome-flag-2",
                  payload: %{"color" => "blue", "animal" => "hedgehog"}
                }}
    end

    test "when feature flag has an array payload, will return decoded payload" do
      stub_with(:hackney, HackneyStubV3)

      assert Posthog.feature_flag("array-payload", "user_123") ==
               {:ok,
                %Posthog.FeatureFlag{
                  enabled: true,
                  name: "array-payload",
                  payload: [0, 1, 2]
                }}
    end

    test "when feature flag does not have a payload, will return flag value" do
      stub_with(:hackney, HackneyStubV3)

      assert Posthog.feature_flag("flag-thats-not-on", "user_123") ==
               {:ok,
                %Posthog.FeatureFlag{
                  enabled: false,
                  name: "flag-thats-not-on",
                  payload: nil
                }}
    end

    test "when feature flag does not exist, returns not_found" do
      stub_with(:hackney, HackneyStubV3)

      assert Posthog.feature_flag("does-not-exist", "user_123") ==
               {:error, :not_found}
    end
  end

  describe "v3 - feature_flag_enabled?/3" do
    test "true if the feature flag is enabled" do
      stub_with(:hackney, HackneyStubV3)

      assert Posthog.feature_flag_enabled?("my-awesome-flag", "user_123")
    end

    test "false if the feature flag is disabled" do
      stub_with(:hackney, HackneyStubV3)

      refute Posthog.feature_flag_enabled?("flag-thats-not-on", "user_123")
    end

    test "false if the feature flag does not exist" do
      stub_with(:hackney, HackneyStubV3)

      refute Posthog.feature_flag_enabled?("flag-does-not-exist", "user_123")
    end
  end
end
