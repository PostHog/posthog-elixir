defmodule PostHog.FeatureFlags.Result do
  @moduledoc """
  Represents the result of a feature flag evaluation.

  This struct contains all the information returned when evaluating a feature flag:
  - `key` - The name of the feature flag
  - `enabled` - Whether the flag is enabled for this user
  - `variant` - The variant assigned to this user (nil for boolean flags)
  - `payload` - The JSON payload configured for this flag/variant (nil if not set)

  ## Examples

      # Boolean flag result
      %PostHog.FeatureFlags.Result{
        key: "my-feature",
        enabled: true,
        variant: nil,
        payload: nil
      }

      # Multivariant flag result with payload
      %PostHog.FeatureFlags.Result{
        key: "my-experiment",
        enabled: true,
        variant: "control",
        payload: %{"button_color" => "blue"}
      }
  """

  @type json :: String.t() | number() | boolean() | nil | [json()] | %{String.t() => json()}

  @type t :: %__MODULE__{
          key: String.t(),
          enabled: boolean(),
          variant: String.t() | nil,
          payload: json()
        }

  @enforce_keys [:key, :enabled]
  defstruct [:key, :enabled, :variant, :payload]

  @doc """
  Returns the value of the feature flag result.

  If a variant is present, returns the variant string. Otherwise, returns the
  enabled boolean status. This provides backwards compatibility with existing
  code that expects a simple value from feature flag checks.

  ## Examples

      iex> result = %PostHog.FeatureFlags.Result{key: "flag", enabled: true, variant: "control", payload: nil}
      iex> PostHog.FeatureFlags.Result.value(result)
      "control"

      iex> result = %PostHog.FeatureFlags.Result{key: "flag", enabled: true, variant: nil, payload: nil}
      iex> PostHog.FeatureFlags.Result.value(result)
      true

      iex> result = %PostHog.FeatureFlags.Result{key: "flag", enabled: false, variant: nil, payload: nil}
      iex> PostHog.FeatureFlags.Result.value(result)
      false
  """
  @spec value(t()) :: boolean() | String.t()
  def value(%__MODULE__{variant: variant}) when not is_nil(variant), do: variant
  def value(%__MODULE__{enabled: enabled}), do: enabled
end
