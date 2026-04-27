defmodule PostHog.FeatureFlags.Result do
  @moduledoc """
  Represents the result of a feature flag evaluation.

  This struct contains all the information returned when evaluating a feature flag:

  - `key` - The name of the feature flag
  - `enabled` - Whether the flag is enabled for this user
  - `variant` - The variant assigned to this user (nil for boolean flags)
  - `payload` - The JSON payload configured for this flag/variant (nil if not set)
  - `id` - Numeric flag ID from the PostHog backend (when available)
  - `version` - Flag version from the PostHog backend (when available)
  - `reason` - Reason map describing why this evaluation produced its value
  - `request_id` - Request ID returned by the `/flags` endpoint (useful for experiment exposure tracking)
  - `evaluated_at` - Server-side evaluation timestamp from the response

  The latter five fields are populated when the `/flags` response includes them
  and are forwarded as `$feature_flag_id`, `$feature_flag_version`, `$feature_flag_reason`,
  `$feature_flag_request_id`, and `$feature_flag_evaluated_at` properties on
  `$feature_flag_called` events.

  ## Examples

      # Boolean flag result
      %PostHog.FeatureFlags.Result{
        key: "my-feature",
        enabled: true,
        variant: nil,
        payload: nil
      }

      # Multivariant flag result with payload and metadata
      %PostHog.FeatureFlags.Result{
        key: "my-experiment",
        enabled: true,
        variant: "control",
        payload: %{"button_color" => "blue"},
        id: 154_429,
        version: 4,
        reason: %{"code" => "condition_match", "description" => "Matched condition set 1"},
        request_id: "0d23f243-399a-4904-b1a8-ec2037834b72",
        evaluated_at: 1_234_567_890
      }
  """

  @type json :: String.t() | number() | boolean() | nil | [json()] | %{String.t() => json()}

  @type t :: %__MODULE__{
          key: String.t(),
          enabled: boolean(),
          variant: String.t() | nil,
          payload: json(),
          id: integer() | nil,
          version: integer() | nil,
          reason: map() | nil,
          request_id: String.t() | nil,
          evaluated_at: integer() | nil
        }

  @enforce_keys [:key, :enabled]
  defstruct [
    :key,
    :enabled,
    :variant,
    :payload,
    :id,
    :version,
    :reason,
    :request_id,
    :evaluated_at
  ]

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
