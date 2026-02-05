defmodule PostHog.Config do
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
                          in_app_otp_apps: [
                            type: {:list, :atom},
                            default: [],
                            doc:
                              "List of OTP app names of your applications. Stacktrace entries that belong to these apps will be marked as \"in_app\"."
                          ],
                          max_retries: [
                            type: :non_neg_integer,
                            default: 3,
                            doc:
                              "Maximum number of retry attempts for failed batch requests."
                          ],
                          gzip: [
                            type: :boolean,
                            default: false,
                            doc: "Enable gzip compression for request bodies."
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
    with {:ok, validated} <- NimbleOptions.validate(options, @compiled_configuration_schema) do
      config = Map.new(validated)

      client_opts = [gzip: config[:gzip] || false]

      client =
        if function_exported?(config.api_client_module, :client, 3) do
          config.api_client_module.client(config.api_key, config.api_host, client_opts)
        else
          config.api_client_module.client(config.api_key, config.api_host)
        end
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
end
