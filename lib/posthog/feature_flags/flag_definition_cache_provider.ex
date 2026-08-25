defmodule PostHog.FeatureFlags.FlagDefinitionCacheProvider do
  @moduledoc """
  Optional shared cache contract for local feature flag definitions.

  Configure a provider as `{module, provider_state}` using
  `:flag_definition_cache_provider`. The definition loader bounds and isolates
  every callback. Cached values must be maps containing `flags`,
  `group_type_mapping`, and `cohorts` (string or atom keys are accepted).

  A minimal provider can coordinate fetching and keep the complete envelope in
  an application-owned cache:

      defmodule MyApp.PostHogDefinitionCache do
        @behaviour PostHog.FeatureFlags.FlagDefinitionCacheProvider

        def should_fetch_flag_definitions(state), do: state.fetch_owner?.()
        def get_flag_definitions(state), do: state.read.()
        def on_flag_definitions_received(state, definitions), do: state.write.(definitions)
        def shutdown(_state), do: :ok
      end

      config :posthog,
        secret_key: System.fetch_env!("POSTHOG_SECRET_KEY"),
        flag_definition_cache_provider: {MyApp.PostHogDefinitionCache, provider_state}
  """

  @type provider_state :: any()
  @type definitions :: map()

  @doc "Returns whether this SDK instance should fetch fresh definitions from PostHog."
  @callback should_fetch_flag_definitions(provider_state()) :: boolean()

  @doc "Reads definitions from the shared cache, or returns nil when it is empty."
  @callback get_flag_definitions(provider_state()) :: definitions() | nil

  @doc "Stores a complete definition envelope fetched from PostHog."
  @callback on_flag_definitions_received(provider_state(), definitions()) :: :ok

  @doc "Releases resources owned by the provider."
  @callback shutdown(provider_state()) :: :ok
end
