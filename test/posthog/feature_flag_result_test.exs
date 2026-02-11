defmodule PostHog.FeatureFlagResultTest do
  use ExUnit.Case, async: true

  alias PostHog.FeatureFlagResult

  describe "struct" do
    test "creates struct with all fields" do
      result = %FeatureFlagResult{
        key: "my-flag",
        enabled: true,
        variant: "control",
        payload: %{"key" => "value"}
      }

      assert result.key == "my-flag"
      assert result.enabled == true
      assert result.variant == "control"
      assert result.payload == %{"key" => "value"}
    end

    test "creates struct with nil defaults" do
      result = %FeatureFlagResult{key: "my-flag", enabled: false}

      assert result.key == "my-flag"
      assert result.enabled == false
      assert result.variant == nil
      assert result.payload == nil
    end
  end

  describe "value/1" do
    test "returns variant when present" do
      result = %FeatureFlagResult{
        key: "my-flag",
        enabled: true,
        variant: "control",
        payload: nil
      }

      assert FeatureFlagResult.value(result) == "control"
    end

    test "returns variant even when empty string" do
      result = %FeatureFlagResult{
        key: "my-flag",
        enabled: true,
        variant: "",
        payload: nil
      }

      # Empty string is still a variant, but per implementation nil check
      # empty string is not nil, so it returns the variant
      assert FeatureFlagResult.value(result) == ""
    end

    test "returns true when enabled and no variant" do
      result = %FeatureFlagResult{
        key: "my-flag",
        enabled: true,
        variant: nil,
        payload: nil
      }

      assert FeatureFlagResult.value(result) == true
    end

    test "returns false when not enabled and no variant" do
      result = %FeatureFlagResult{
        key: "my-flag",
        enabled: false,
        variant: nil,
        payload: nil
      }

      assert FeatureFlagResult.value(result) == false
    end

    test "variant takes precedence over enabled status" do
      # Edge case: variant present but enabled is false
      result = %FeatureFlagResult{
        key: "my-flag",
        enabled: false,
        variant: "test-variant",
        payload: nil
      }

      assert FeatureFlagResult.value(result) == "test-variant"
    end
  end
end
