defmodule PosthogTest do
  use ExUnit.Case, async: true
  import Mimic

  describe "feature_flag/3" do
    test "when feature flag exists, returns feature flag struct" do
      stub_with(:hackney, HackneyStub)

      assert Posthog.feature_flag("my-awesome-flag", "user_123") ==
               {:ok,
                %Posthog.FeatureFlag{
                  enabled: true,
                  name: "my-awesome-flag",
                  value: "example-payload-string"
                }}
    end

    test "when feature flag has a json payload, will return decoded payload" do
      stub_with(:hackney, HackneyStub)

      assert Posthog.feature_flag("my-awesome-flag-2", "user_123") ==
               {:ok,
                %Posthog.FeatureFlag{
                  enabled: true,
                  name: "my-awesome-flag-2",
                  value: %{"color" => "blue", "animal" => "hedgehog"}
                }}
    end

    test "when feature flag does not have a payload, will return flag value" do
      stub_with(:hackney, HackneyStub)

      assert Posthog.feature_flag("flag-thats-not-on", "user_123") ==
               {:ok,
                %Posthog.FeatureFlag{
                  enabled: false,
                  name: "flag-thats-not-on",
                  value: nil
                }}
    end

    test "when feature flag does not exist, returns not_found" do
      stub_with(:hackney, HackneyStub)

      assert Posthog.feature_flag("does-not-exist", "user_123") ==
               {:error, :not_found}
    end
  end

  describe "feature_flag_enabled?/3" do
    test "true if the feature flag is enabled" do
      stub_with(:hackney, HackneyStub)

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
end
