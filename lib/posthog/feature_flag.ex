defmodule Posthog.FeatureFlag do
  @moduledoc """
  Represents a PostHog feature flag with its evaluation state.

  This module provides a struct and helper functions for working with PostHog feature flags.
  Feature flags can be either boolean (on/off) or multivariate (multiple variants).

  ## Structure

  The `FeatureFlag` struct contains:
    * `name` - The name of the feature flag
    * `value` - The payload value associated with the flag (can be any term)
    * `enabled` - The evaluation result (boolean for on/off flags, string for multivariate flags)

  ## Examples

      # Boolean feature flag
      %Posthog.FeatureFlag{
        name: "new-dashboard",
        value: true,
        enabled: true
      }

      # Multivariate feature flag
      %Posthog.FeatureFlag{
        name: "pricing-test",
        value: %{"price" => 99, "period" => "monthly"},
        enabled: "variant-a"
      }
  """
  defstruct [:name, :value, :enabled]

  @typedoc """
  Represents the enabled state of a feature flag.
  Can be either a boolean for on/off flags or a string for multivariate flags.
  """
  @type variant :: binary() | boolean()

  @typedoc """
  A map of properties that can be associated with a feature flag.
  """
  @type properties :: %{optional(binary()) => term()}

  @typedoc """
  The response format from PostHog's feature flag API.
  Contains both the flag states and their associated payloads.
  """
  @type flag_response :: %{
          feature_flags: %{optional(binary()) => variant()},
          feature_flag_payloads: %{optional(binary()) => term()}
        }

  @typedoc """
  The FeatureFlag struct type.

  Fields:
    * `name` - The name of the feature flag (string)
    * `value` - The payload value associated with the flag (any term)
    * `enabled` - The evaluation result (boolean or string)
  """
  @type t :: %__MODULE__{
          name: binary(),
          value: term(),
          enabled: variant()
        }

  @doc """
  Creates a new FeatureFlag struct.

  ## Parameters

    * `name` - The name of the feature flag
    * `enabled` - The evaluation result (boolean or string)
    * `value` - The payload value associated with the flag

  ## Examples

      # Create a boolean feature flag
      Posthog.FeatureFlag.new("new-dashboard", true, true)

      # Create a multivariate feature flag
      Posthog.FeatureFlag.new("pricing-test", "variant-a",
        %{"price" => 99, "period" => "monthly"})
  """
  @spec new(binary(), variant(), term()) :: t()
  def new(name, enabled, value) do
    struct!(__MODULE__, name: name, enabled: enabled, value: value)
  end

  @doc """
  Checks if a feature flag is a boolean flag.

  Returns `true` if the flag is a boolean (on/off) flag, `false` if it's a multivariate flag.

  ## Examples

      flag = Posthog.FeatureFlag.new("new-dashboard", true, true)
      Posthog.FeatureFlag.boolean?(flag)
      # Returns: true

      flag = Posthog.FeatureFlag.new("pricing-test", "variant-a", %{})
      Posthog.FeatureFlag.boolean?(flag)
      # Returns: false
  """
  @spec boolean?(t()) :: boolean()
  def boolean?(%__MODULE__{enabled: value}), do: is_boolean(value)
end
