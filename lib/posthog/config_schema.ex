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
        A privileged project secret (`phs_`) or appropriately scoped personal API key (`phx_`).
        Fetches local feature flag definitions directly from PostHog. A configured
        `flag_definition_cache_provider` can supply definitions without this key.
        `PostHog.Emails` needs a project secret API key with the `hog_flow:write` scope to send
        email, or `hog_flow:read` to read an email's status.
        """
      ],
      app_host: [
        type: {:or, [{:custom, __MODULE__, :http_url, []}, nil]},
        default: nil,
        doc: """
        The PostHog app host that `PostHog.Emails` sends to, such as `https://posthog.example.com`
        for a self-hosted instance. Without it, a PostHog Cloud `api_host` maps to its region's app
        host, and any other `api_host` makes email calls fail with `missing_app_host`, so email
        requests never send the secret key to a reverse proxy for ingestion. Local flag
        evaluation still fetches definitions from `api_host` with `secret_key`; set
        `enable_local_evaluation: false` when the proxy must not see the key.
        """
      ],
      email_request_timeout_ms: [
        type: :pos_integer,
        default: 15_000,
        doc: "Maximum time in milliseconds to wait for each `PostHog.Emails` request."
      ],
      email_request_max_retries: [
        type: :non_neg_integer,
        default: 2,
        doc: """
        Number of retries for a `PostHog.Emails` request after a network error, a rate limit, an
        idempotency key still in flight, or an unavailable service. Set to 0 when a job runner
        already retries the send.
        """
      ],
      migrated_from: [
        type: {:or, [{:custom, __MODULE__, :header_token, []}, nil]},
        default: nil,
        doc: """
        The email provider you moved from, such as `"resend"`. Sent with every `PostHog.Emails`
        request as `X-PostHog-Migrated-From`.
        """
      ],
      enable_local_evaluation: [
        type: :boolean,
        default: true,
        doc:
          "Enable local feature flag evaluation when a non-empty `secret_key` or a `flag_definition_cache_provider` is configured."
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

  @doc false
  def http_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        {:ok, value}

      _other ->
        {:error, "expected an absolute http or https URL, got: #{inspect(value)}"}
    end
  end

  def http_url(value), do: {:error, "expected a string, got: #{inspect(value)}"}

  @doc false
  def header_token(value) when is_binary(value) do
    if value =~ ~r/\A[\x21-\x7e]+\z/ do
      {:ok, value}
    else
      {:error, "expected visible ASCII characters without spaces, got: #{inspect(value)}"}
    end
  end

  def header_token(value), do: {:error, "expected a string, got: #{inspect(value)}"}

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
