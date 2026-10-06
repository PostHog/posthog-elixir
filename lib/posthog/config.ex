defmodule PostHog.Config do
  require Logger
  alias PostHog.Config.Schema

  defmodule Secret do
    @moduledoc false
    @enforce_keys [:value]
    defstruct [:value]

    @type t :: %__MODULE__{value: String.t()}

    @doc false
    @spec new(String.t()) :: t()
    def new(value) when is_binary(value), do: %__MODULE__{value: value}

    @doc false
    @spec reveal(t()) :: String.t()
    def reveal(%__MODULE__{value: value}), do: value
  end

  defimpl Inspect, for: Secret do
    import Inspect.Algebra

    def inspect(_secret, _opts), do: concat(["#PostHog.Config.Secret<redacted>"])
  end

  @default_api_host "https://us.i.posthog.com"

  @compiled_configuration_schema NimbleOptions.new!(Schema.configuration())
  @compiled_convenience_schema NimbleOptions.new!(Schema.convenience())

  @system_global_properties %{
    "$lib": PostHog.Lib.name(),
    "$lib_version": PostHog.Lib.version()
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
      |> Keyword.take(Keyword.keys(Schema.configuration()))

    convenience_options =
      Application.get_all_env(:posthog)
      |> Keyword.take(Keyword.keys(Schema.convenience()))

    convenience_options
    |> NimbleOptions.validate!(Schema.convenience())
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

  String `:api_key`, `:secret_key`, and `:api_host` values are trimmed before validation. A blank
  `:api_host` falls back to the default PostHog US ingestion host.
  """
  @spec validate(options()) ::
          {:ok, config()} | {:error, NimbleOptions.ValidationError.t()}
  def validate(options) do
    normalized_options = normalize_options(options)

    with {:ok, validated} <-
           NimbleOptions.validate(normalized_options, Schema.configuration()) do
      api_key_blank? = blank_api_key?(validated)
      log_blank_api_key(validated)

      config = Map.new(validated)

      client =
        if api_key_blank? do
          nil
        else
          config.api_client_module.client(config.api_key, config.api_host)
          |> Map.put(:feature_flags_request_max_retries, config.feature_flags_request_max_retries)
        end

      system_global_properties =
        if config.is_server do
          Map.put(@system_global_properties, :"$is_server", true)
        else
          @system_global_properties
        end

      global_properties = Map.merge(config.global_properties, system_global_properties)

      final_config =
        config
        |> Map.update!(:secret_key, fn
          nil -> nil
          secret_key -> Secret.new(secret_key)
        end)
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
      if Keyword.has_key?(normalized_options, :secret_key) do
        Keyword.update!(normalized_options, :secret_key, &normalize_secret_key/1)
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
  defp normalize_api_key(nil), do: ""
  defp normalize_api_key(api_key), do: api_key

  defp normalize_secret_key(secret_key) when is_binary(secret_key) do
    case String.trim(secret_key) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_secret_key(secret_key), do: secret_key

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
      Logger.warning(
        "posthog api_key is empty after trimming whitespace; PostHog will start in disabled/no-op mode",
        posthog_skip_capture: true
      )
    end
  end
end
