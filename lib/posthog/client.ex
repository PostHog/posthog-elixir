defmodule Posthog.Client do
  @moduledoc """
  Low-level HTTP client for interacting with PostHog's API.

  This module handles the direct HTTP communication with PostHog's API endpoints.
  It provides functions for:
  - Sending event capture requests
  - Processing batch events
  - Retrieving feature flag information

  While this module can be used directly, it's recommended to use the higher-level
  functions in the `Posthog` module instead.

  ## Configuration

  The client uses the following configuration from your application:

      config :posthog,
        api_url: "https://app.posthog.com",  # Required
        api_key: "phc_your_project_api_key", # Required
        json_library: Jason,                 # Optional (default: Jason)
        version: 3                          # Optional (default: 3)

  ## API Endpoints

  The client interacts with the following PostHog API endpoints:
  - `/capture` - For sending individual and batch events
  - `/decide` - For retrieving feature flag information

  ## Error Handling

  All functions return a result tuple:
  - `{:ok, response}` for successful requests
  - `{:error, response}` for failed requests with a response
  - `{:error, term()}` for other errors (network issues, etc.)

  ## Examples

      # Capture an event
      Posthog.Client.capture("page_view", %{distinct_id: "user_123"})

      # Send batch events
      events = [
        {"page_view", %{distinct_id: "user_123"}, nil},
        {"click", %{distinct_id: "user_123"}, DateTime.utc_now()}
      ]
      Posthog.Client.batch(events)

      # Get feature flags
      Posthog.Client.feature_flags("user_123", groups: %{team: "engineering"})
  """

  @app :posthog

  @typedoc """
  HTTP headers in the format expected by :hackney.
  """
  @type headers :: [{binary(), binary()}]

  @typedoc """
  Response from the PostHog API.
  Contains the status code, headers, and parsed JSON body (if any).
  """
  @type response :: %{status: pos_integer(), headers: headers(), body: map() | nil}

  @typedoc """
  Event name, can be either an atom or a binary string.
  """
  @type event :: atom() | binary()

  @typedoc """
  Properties that can be attached to events or feature flag requests.
  """
  @type properties :: %{optional(atom() | String.t()) => term()}

  @typedoc """
  Timestamp for events. Can be a DateTime, NaiveDateTime, or ISO8601 string.
  """
  @type timestamp :: String.t()

  @typedoc """
  Options that can be passed to API requests.

  * `:headers` - Additional HTTP headers to include in the request
  * `:groups` - Group properties for feature flag evaluation
  * `:group_properties` - Additional properties for groups
  * `:person_properties` - Properties for the person
  * `:timestamp` - Custom timestamp for events
  """
  @type opts :: [
          headers: headers(),
          groups: map(),
          group_properties: map(),
          person_properties: map(),
          timestamp: timestamp(),
          uuid: UUIDv7.t()
        ]

  @lib_version Mix.Project.config()[:version]
  @lib_name "posthog-elixir"

  import Posthog.Guard, only: [is_keyword_list: 1]

  # Adds default headers to the request.
  #
  # ## Parameters
  #
  #   * `additional_headers` - List of additional headers to include
  #
  # ## Examples
  #
  #     headers([{"x-forwarded-for", "127.0.0.1"}])
  @spec headers(headers()) :: headers()
  defp headers(additional_headers \\ []) do
    Enum.concat(additional_headers || [], [{"content-type", "application/json"}])
  end

  @doc """
  Captures a single event in PostHog.

  ## Parameters

    * `event` - The name of the event (string or atom)
    * `params` - Event properties including `:distinct_id`
    * `opts` - Additional options (see `t:opts/0`)

  ## Examples

      # Basic event
      Posthog.Client.capture("page_view", %{distinct_id: "user_123"})

      # Event with properties and timestamp
      Posthog.Client.capture("purchase",
        %{
          distinct_id: "user_123",
          product_id: "123",
          price: 99.99
        },
        timestamp: DateTime.utc_now()
      )

      # Event with custom headers
      Posthog.Client.capture("login",
        %{distinct_id: "user_123"},
        headers: [{"x-forwarded-for", "127.0.0.1"}]
      )
  """
  @spec capture(event(), properties(), opts() | timestamp()) ::
          {:ok, response()} | {:error, response() | term()}
  def capture(event, params, opts) when is_list(opts) do
    uuid = Keyword.get(opts, :uuid, &UUIDv7.generate/0)

    timestamp =
      Keyword.get_lazy(opts, :timestamp, fn ->
        DateTime.to_iso8601(DateTime.utc_now())
      end)

    post!("/capture", build_event(event, params, timestamp, uuid), headers(opts[:headers]))
  end

  @deprecated "Use capture/3 with keyword list opts instead"
  def capture(event, params, timestamp) when is_bitstring(event) or is_atom(event) do
    post!("/capture", build_event(event, params, timestamp), headers())
  end

  @doc """
  Sends multiple events to PostHog in a single request.

  ## Parameters

    * `events` - List of event tuples in the format `{event_name, properties, timestamp}`
    * `opts` - Additional options (see `t:opts/0`)
    * `headers` - Additional HTTP headers

  ## Examples

      events = [
        {"page_view", %{distinct_id: "user_123"}, nil},
        {"click", %{distinct_id: "user_123", button: "signup"}, DateTime.utc_now()}
      ]

      Posthog.Client.batch(events)
  """
  @spec batch([{event(), properties(), timestamp()}], opts() | any(), headers()) ::
          {:ok, response()} | {:error, response() | term()}
  def batch(events, opts) when is_list(opts) do
    batch(events, opts, headers(opts[:headers]))
  end

  def batch(events, _opts, headers) do
    body = for {event, params, timestamp} <- events, do: build_event(event, params, timestamp)

    post!("/capture", %{batch: body}, headers)
  end

  @doc """
  Retrieves feature flags for a given distinct ID.

  ## Parameters

    * `distinct_id` - The unique identifier for the user
    * `opts` - Additional options (see `t:opts/0`)

  ## Examples

      # Basic feature flags request
      Posthog.Client.feature_flags("user_123")

      # With group properties
      Posthog.Client.feature_flags("user_123",
        groups: %{company: "company_123"},
        group_properties: %{company: %{industry: "tech"}}
      )
  """
  @spec feature_flags(binary(), opts()) ::
          {:ok, Posthog.FeatureFlag.flag_response()} | {:error, response() | term()}
  def feature_flags(distinct_id, opts) do
    body =
      opts
      |> Keyword.take(~w[groups group_properties person_properties]a)
      |> Enum.reduce(%{distinct_id: distinct_id}, fn {k, v}, map -> Map.put(map, k, v) end)

    case post!("/decide", body, headers(opts[:headers])) do
      {:ok, %{body: body}} ->
        {:ok,
         %{
           feature_flags: Map.get(body, "featureFlags", %{}),
           feature_flag_payloads: decode_feature_flag_payloads(body)
         }}

      err ->
        err
    end
  end

  @doc """
  Builds an event payload for the PostHog API.

  ## Parameters

    * `event` - The name of the event
    * `properties` - Event properties
    * `timestamp` - Optional timestamp for the event
    * `uuid` - Optional UUID for the event

  ## Examples

      build_event("page_view", %{distinct_id: "user_123"}, nil)
      build_event("purchase", %{distinct_id: "user_123", price: 99.99}, DateTime.utc_now())
  """
  @spec build_event(event(), properties(), timestamp()) :: map()
  def build_event(event, properties, timestamp, uuid \\ UUIDv7.generate()) do
    properties = Map.merge(lib_properties(), deep_stringify_keys(Map.new(properties)))
    %{event: to_string(event), properties: properties, timestamp: timestamp, uuid: uuid}
  end

  @doc false
  defp deep_stringify_keys(term) when is_map(term) do
    term
    |> Enum.map(fn {k, v} -> {to_string(k), deep_stringify_keys(v)} end)
    |> Enum.into(%{})
  end

  defp deep_stringify_keys(term) when is_keyword_list(term) do
    term
    |> Enum.map(fn {k, v} -> {to_string(k), deep_stringify_keys(v)} end)
    |> Enum.into(%{})
  end

  defp deep_stringify_keys(term) when is_list(term), do: Enum.map(term, &deep_stringify_keys/1)
  defp deep_stringify_keys(term), do: term

  @doc false
  @spec post!(binary(), map(), headers()) :: {:ok, response()} | {:error, response() | term()}
  defp post!(path, %{} = body, headers) do
    body =
      body
      |> Map.put(:api_key, api_key())
      |> encode(json_library())

    url = api_url() <> path <> "?v=#{api_version()}"

    :hackney.post(url, headers, body, [])
    |> handle()
  end

  @doc false
  @spec handle(tuple()) :: {:ok, response()} | {:error, response() | term()}
  defp handle({:ok, status, _headers, _ref} = resp) when div(status, 100) == 2 do
    {:ok, to_response(resp)}
  end

  defp handle({:ok, _status, _headers, _ref} = resp) do
    {:error, to_response(resp)}
  end

  defp handle({:error, _} = result) do
    result
  end

  @doc false
  @spec to_response({:ok, pos_integer(), headers(), reference()}) :: response()
  defp to_response({_, status, headers, ref}) do
    response = %{status: status, headers: headers, body: nil}

    with {:ok, body} <- :hackney.body(ref),
         {:ok, json} <- json_library().decode(body) do
      %{response | body: json}
    else
      _ -> response
    end
  end

  @doc false
  @spec api_url() :: binary()
  defp api_url do
    case Application.get_env(@app, :api_url) do
      url when is_bitstring(url) ->
        url

      term ->
        raise """
        Expected a string API URL, got: #{inspect(term)}. Set a
        URL and key in your config:

            config :posthog,
              api_url: "https://posthog.example.com",
              api_key: "my-key"
        """
    end
  end

  @doc false
  @spec api_key() :: binary()
  defp api_key do
    case Application.get_env(@app, :api_key) do
      key when is_bitstring(key) ->
        key

      term ->
        raise """
        Expected a string API key, got: #{inspect(term)}. Set a
        URL and key in your config:

            config :posthog,
              api_url: "https://posthog.example.com",
              api_key: "my-key"
        """
    end
  end

  @doc false
  @spec encode(term(), module()) :: iodata()
  defp encode(data, Jason), do: Jason.encode_to_iodata!(data)
  defp encode(data, library), do: library.encode!(data)

  @doc false
  @spec json_library() :: module()
  defp json_library do
    Application.get_env(@app, :json_library, Jason)
  end

  @doc false
  @spec api_version() :: pos_integer()
  defp api_version do
    Application.get_env(@app, :version, 3)
  end

  @doc false
  @spec lib_properties() :: map()
  defp lib_properties do
    %{
      "$lib" => @lib_name,
      "$lib_version" => @lib_version
    }
  end

  defp decode_feature_flag_payloads(data) do
    data
    |> Map.get("featureFlagPayloads", %{})
    |> Enum.reduce(%{}, fn {k, v}, map ->
      Map.put(map, k, decode_feature_flag_payload(v))
    end)
  end

  defp decode_feature_flag_payload(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> decoded
      {:error, _} -> payload
    end
  end
end
