defmodule PostHog.FeatureFlags.ResultTest do
  use ExUnit.Case, async: true

  alias PostHog.FeatureFlags.Result

  describe "struct" do
    test "creates struct with all fields" do
      result = %Result{
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
      result = %Result{key: "my-flag", enabled: false}

      assert result.key == "my-flag"
      assert result.enabled == false
      assert result.variant == nil
      assert result.payload == nil
    end
  end

  describe "value/1" do
    test "returns variant when present" do
      result = %Result{
        key: "my-flag",
        enabled: true,
        variant: "control",
        payload: nil
      }

      assert Result.value(result) == "control"
    end

    test "returns variant even when empty string" do
      result = %Result{
        key: "my-flag",
        enabled: true,
        variant: "",
        payload: nil
      }

      # Empty string is still a variant, but per implementation nil check
      # empty string is not nil, so it returns the variant
      assert Result.value(result) == ""
    end

    test "returns true when enabled and no variant" do
      result = %Result{
        key: "my-flag",
        enabled: true,
        variant: nil,
        payload: nil
      }

      assert Result.value(result) == true
    end

    test "returns false when not enabled and no variant" do
      result = %Result{
        key: "my-flag",
        enabled: false,
        variant: nil,
        payload: nil
      }

      assert Result.value(result) == false
    end

    test "variant takes precedence over enabled status" do
      # Edge case: variant present but enabled is false
      result = %Result{
        key: "my-flag",
        enabled: false,
        variant: "test-variant",
        payload: nil
      }

      assert Result.value(result) == "test-variant"
    end
  end
end
