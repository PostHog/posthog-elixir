defmodule PostHog.Config do
  require Logger

  @default_api_host "https://us.i.posthog.com"

  @shared_schema [
    test_mode: [
      type: :boolean,
      default: false,
      doc:
        "Test mode keeps captured events in memory for assertions instead of sending them to PostHog."
    ]
  ]

  @configuration_schema [
                          api_host: [
                            type: :string,
                            default: @default_api_host,
                            doc:
                              "`https://us.i.posthog.com` for US cloud or `https://eu.i.posthog.com` for EU cloud"
                          ],
                          api_key: [
                            type: :string,
                            required: true,
                            doc: """
                            Your PostHog Project API key. Find it in your project's settings under the Project ID section.
                            """
                          ],
                          api_client_module: [
                            type: :atom,
                            default: PostHog.API.Client,
                            doc: "API client to use"
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
                          sender_pool_size: [
                            type: :pos_integer,
                            doc:
                              "Number of background sender workers used to batch and send events. Defaults to `max(System.schedulers_online(), 2)`."
                          ],
                          max_batch_time_ms: [
                            type: :non_neg_integer,
                            doc:
                              "Maximum time, in milliseconds, to wait before flushing a non-empty event batch. Defaults to `10_000`."
                          ],
                          max_batch_events: [
                            type: :pos_integer,
                            doc:
                              "Maximum number of events to collect before flushing a batch immediately. Defaults to `100`."
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
                            doc:
                              "Number of source lines to include before and after the error line in stack frames."
                          ],
                          source_code_map_path: [
                            type: :string,
                            doc:
                              "Custom path to a packaged source map file. Defaults to `priv/posthog_source.map` in the `:posthog` application directory."
                          ]
                        ] ++ @shared_schema

  @convenience_schema [
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
                      ] ++ @shared_schema

  @compiled_configuration_schema NimbleOptions.new!(@configuration_schema)
  @compiled_convenience_schema NimbleOptions.new!(@convenience_schema)

  @system_global_properties %{
    "$lib": "posthog-elixir",
    "$lib_version": Mix.Project.config()[:version]
  }

  @moduledoc """
  PostHog configuration

  ## Configuration Schema

  ### Application Configuration

  These are convenience options that only affect how PostHog's own application behaves.

  #{NimbleOptions.docs(@compiled_convenience_schema)}

  ### Supervisor Configuration

  This is the main options block that configures each supervision tree instance.

  #{NimbleOptions.docs(@compiled_configuration_schema)}
  """

  @typedoc """
  Map containing validated configuration for a PostHog supervision tree.

  It mostly follows `t:options/0`, but also includes runtime values such as the
  initialized API client, resolved in-app modules, and system global properties.
  The internal structure should not be relied upon outside of starting
  `PostHog.Supervisor` or reading values through `PostHog.config/1`.
  """
  @opaque config() :: map()

  @typedoc """
  Keyword options accepted by `validate/1` and `validate!/1`.

  See the module documentation for the full schema, defaults, and remarks for
  each configuration option.
  """
  @type options() :: unquote(NimbleOptions.option_typespec(@compiled_configuration_schema))

  @doc false
  def read!() do
    configuration_options =
      Application.get_all_env(:posthog)
      |> Keyword.take(Keyword.keys(@configuration_schema))

    convenience_options =
      Application.get_all_env(:posthog)
      |> Keyword.take(Keyword.keys(@convenience_schema))

    convenience_options
    |> NimbleOptions.validate!(@compiled_convenience_schema)
    |> Map.new()
    |> case do
      %{enable: true} = conv ->
        config = validate!(configuration_options)
        {conv, config}

      conv ->
        {conv, nil}
    end
  end

  @doc """
  Validates configuration and returns a `t:config/0`, raising if validation fails.

  See `validate/1` for the accepted options and return shape.
  """
  @spec validate!(options()) :: config()
  def validate!(options) do
    {:ok, config} = validate(options)
    config
  end

  @doc """
  Validates configuration against the supervisor schema.

  ## Parameters

  - `options` - keyword list matching `t:options/0`.

  ## Returns

  Returns `{:ok, config}` with a normalized `t:config/0` on success, or
  `{:error, %NimbleOptions.ValidationError{}}` when the options are invalid.

  ## Remarks

  String `:api_key` and `:api_host` values are trimmed before validation. A blank
  `:api_host` falls back to the default PostHog US ingestion host.
  """
  @spec validate(options()) ::
          {:ok, config()} | {:error, NimbleOptions.ValidationError.t()}
  def validate(options) do
    normalized_options = normalize_options(options)

    with {:ok, validated} <-
           NimbleOptions.validate(normalized_options, @compiled_configuration_schema) do
      log_blank_api_key(validated)

      config = Map.new(validated)
      client = config.api_client_module.client(config.api_key, config.api_host)
      global_properties = Map.merge(config.global_properties, @system_global_properties)

      final_config =
        config
        |> Map.put(:api_client, client)
        |> Map.put(
          :in_app_modules,
          config.in_app_otp_apps |> Enum.flat_map(&Application.spec(&1, :modules)) |> MapSet.new()
        )
        |> Map.put(:global_properties, global_properties)

      {:ok, final_config}
    end
  end

  defp normalize_options(options) do
    options
    |> then(fn normalized_options ->
      if Keyword.has_key?(normalized_options, :api_key) do
        Keyword.update!(normalized_options, :api_key, &normalize_api_key/1)
      else
        normalized_options
      end
    end)
    |> then(fn normalized_options ->
      if Keyword.has_key?(normalized_options, :api_host) do
        Keyword.update!(normalized_options, :api_host, &normalize_api_host/1)
      else
        normalized_options
      end
    end)
  end

  defp normalize_api_key(api_key) when is_binary(api_key), do: String.trim(api_key)
  defp normalize_api_key(api_key), do: api_key

  defp normalize_api_host(api_host) when is_binary(api_host) do
    api_host
    |> String.trim()
    |> case do
      "" -> @default_api_host
      normalized_api_host -> normalized_api_host
    end
  end

  defp normalize_api_host(api_host), do: api_host

  defp log_blank_api_key(validated) do
    if validated[:api_key] == "" do
      Logger.error(
        "posthog api_key is empty after trimming whitespace; check your project API key"
      )
    end
  end
end
