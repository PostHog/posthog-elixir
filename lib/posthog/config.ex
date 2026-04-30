defmodule PostHog.Config do
  require Logger

  @shared_schema [
    test_mode: [
      type: :boolean,
      default: false,
      doc: "Test mode allows tests assert captured events."
    ]
  ]

  @configuration_schema [
                          api_host: [
                            type: :string,
                            required: true,
                            doc:
                              "`https://us.i.posthog.com` for US cloud or `https://eu.i.posthog.com` for EU cloud"
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

  @default_api_host "https://us.i.posthog.com"

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
  Map containing valid configuration.

  It mostly follows `t:options/0`, but the internal structure shouldn't be relied upon.
  """
  @opaque config() :: map()

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
  See `validate/1`.
  """
  @spec validate!(options()) :: config()
  def validate!(options) do
    {:ok, config} = validate(options)
    config
  end

  @doc """
  Validates configuration against the schema.
  """
  @spec validate(options()) ::
          {:ok, config()} | {:error, NimbleOptions.ValidationError.t()}
  def validate(options) do
    normalized_options = normalize_options(options)

    with {:ok, validated} <-
           NimbleOptions.validate(normalized_options, @compiled_configuration_schema) do
      api_key_blank? = blank_api_key?(validated)
      log_blank_api_key(validated)

      config = Map.new(validated)

      client =
        if api_key_blank? do
          nil
        else
          config.api_client_module.client(config.api_key, config.api_host)
        end

      global_properties = Map.merge(config.global_properties, @system_global_properties)

      final_config =
        config
        |> Map.put(:api_client, client)
        |> Map.put(:enabled, not api_key_blank?)
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
    |> then(fn normalized_options ->
      if disabled_options?(normalized_options) and
           not Keyword.has_key?(normalized_options, :api_host) do
        Keyword.put(normalized_options, :api_host, @default_api_host)
      else
        normalized_options
      end
    end)
  end

  defp normalize_api_key(api_key) when is_binary(api_key), do: String.trim(api_key)
  defp normalize_api_key(api_key), do: api_key

  defp disabled_options?(options), do: Keyword.get(options, :api_key, "") == ""

  defp normalize_api_host(api_host) when is_binary(api_host) do
    api_host
    |> String.trim()
    |> case do
      "" -> @default_api_host
      normalized_api_host -> normalized_api_host
    end
  end

  defp normalize_api_host(api_host), do: api_host

  defp blank_api_key?(validated), do: validated[:api_key] == ""

  defp log_blank_api_key(validated) do
    if blank_api_key?(validated) do
      Logger.error(
        "posthog api_key is empty after trimming whitespace; PostHog will start in disabled/no-op mode"
      )
    end
  end
end
