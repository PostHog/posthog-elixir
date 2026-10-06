defmodule PostHog.Config.Schema do
  @moduledoc false
  @default_api_host "https://us.i.posthog.com"

  def shared do
    [
      test_mode: [
        type: :boolean,
        default: false,
        doc:
          "Test mode keeps captured events in memory for assertions instead of sending them to PostHog."
      ]
    ]
  end

  def configuration do
    [
      api_host: [
        type: :string,
        default: @default_api_host,
        doc: "`https://us.i.posthog.com` for US cloud or `https://eu.i.posthog.com` for EU cloud"
      ],
      api_key: [
        type: :string,
        default: "",
        doc: """
        Your PostHog Project API key. Find it in your project's settings under the Project ID section.
        If omitted or empty after trimming whitespace, PostHog starts in disabled/no-op mode.
        """
      ],
      api_client_module: [
        type: :atom,
        default: PostHog.API.Client,
        doc: "API client to use"
      ],
      feature_flags_request_max_retries: [
        type: :non_neg_integer,
        default: 1,
        doc:
          "Number of retries for /flags requests after network, transport, or timeout failures. Set to 0 to disable retries."
      ],
      secret_key: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: """
        A privileged project secret (`phs_`) or appropriately scoped personal API key (`phx_`)
        used only to load definitions for local feature flag evaluation. Local evaluation is inert
        and starts no poller when this value is absent or blank.
        """
      ],
      enable_local_evaluation: [
        type: :boolean,
        default: true,
        doc: "Enable local feature flag evaluation when a non-empty `secret_key` is configured."
      ],
      feature_flags_poll_interval_ms: [
        type: :pos_integer,
        default: 30_000,
        doc: "Interval in milliseconds between local feature flag definition refreshes."
      ],
      flag_definition_cache_provider: [
        type: {:or, [{:tuple, [:atom, :any]}, nil]},
        default: nil,
        doc:
          "Optional `{module, state}` implementing `PostHog.FeatureFlags.FlagDefinitionCacheProvider`."
      ],
      flag_definition_cache_provider_timeout_ms: [
        type: :pos_integer,
        default: 5_000,
        doc: "Maximum time in milliseconds allowed for each definition cache provider callback."
      ],
      flag_definition_request_timeout_ms: [
        type: :pos_integer,
        default: 10_000,
        doc: "Maximum time in milliseconds allowed for a local feature flag definition request."
      ],
      supervisor_name: [
        type: :atom,
        default: PostHog,
        doc: "Name of the supervisor process running PostHog"
      ],
      metadata: [
        type: {:or, [{:list, :atom}, {:in, [:all]}]},
        default: [],
        doc:
          "List of Logger metadata keys to include in event properties. Set to `:all` to include all metadata. This only affects Error Tracking events."
      ],
      capture_level: [
        type: {:or, [{:in, Logger.levels()}, nil]},
        default: :error,
        doc:
          "Minimum level for logs that should be captured as errors. Errors with `crash_reason` are always captured."
      ],
      global_properties: [
        type: :map,
        default: %{},
        doc: "Map of properties that should be added to all events"
      ],
      before_send: [
        type: {:or, [{:fun, 1}, nil]},
        default: nil,
        doc:
          "Callback invoked with the fully enriched event before it is queued. Return the event to send a modified version, or nil to drop it."
      ],
      is_server: [
        type: :boolean,
        default: true,
        doc:
          "Whether this SDK runs as a server. When `true` (the default), a `$is_server: true` property is added to all events so PostHog attributes them as server-side. Set to `false` when using posthog-elixir as a client/CLI so the device OS is attributed normally."
      ],
      in_app_otp_apps: [
        type: {:list, :atom},
        default: [],
        doc:
          "List of OTP app names of your applications. Stacktrace entries that belong to these apps will be marked as \"in_app\"."
      ],
      enable_source_code_context: [
        type: :boolean,
        default: false,
        doc:
          "Enable source code context in error tracking stack frames. Requires source code to be available at runtime or packaged via `mix posthog.package_source_code`."
      ],
      root_source_code_paths: [
        type: {:list, :string},
        default: [],
        doc:
          "List of root paths to scan for source files. Used by the source context feature and `mix posthog.package_source_code`."
      ],
      source_code_path_pattern: [
        type: :string,
        default: "**/*.ex",
        doc: "Glob pattern for source files to include in source context."
      ],
      source_code_exclude_patterns: [
        type: {:list, {:struct, Regex}},
        default: [~r"^_build/", ~r"^priv/", ~r"^test/"],
        doc:
          ~s(List of regex patterns to exclude from source context. Defaults to excluding `_build/`, `priv/`, and `test/` directories.)
      ],
      context_lines: [
        type: :non_neg_integer,
        default: 5,
        doc: "Number of source lines to include before and after the error line in stack frames."
      ],
      source_code_map_path: [
        type: :string,
        doc:
          "Custom path to a packaged source map file. Defaults to `priv/posthog_source.map` in the `:posthog` application directory."
      ]
    ] ++ shared()
  end

  def convenience do
    [
      enable: [
        type: :boolean,
        default: true,
        doc: "Automatically start PostHog?"
      ],
      enable_error_tracking: [
        type: :boolean,
        default: true,
        doc: "Automatically start the logger handler for error tracking?"
      ]
    ] ++ shared()
  end
end
