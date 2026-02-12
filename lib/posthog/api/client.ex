defmodule PostHog.API.Client do
  @moduledoc """
  Behaviour and the default implementation of a PostHog API client. Uses `Req`.

  The default client sends request bodies gzip-compressed and retries on transient
  failures. If you need different behaviour — for example, to disable compression,
  add custom headers, attach telemetry, or use a different HTTP library — you can
  implement this behaviour in your own module and configure it via `api_client_module`.

  ## Using the default client directly

      > client = PostHog.API.Client.client("phc_abcdedfgh", "https://us.i.posthog.com")
      %PostHog.API.Client{
        client: %Req.Request{...},
        module: PostHog.API.Client
      }

      > client.module.request(client.client, :post, "/flags", json: %{distinct_id: "user123"}, params: %{v: 2, config: true})
      {:ok, %Req.Response{status: 200, body: %{...}}}

  ## Writing a custom client

  Implement the `client/2` and `request/4` callbacks, then set the config:

      config :posthog, api_client_module: MyApp.PostHogClient

  ### Wrapping the default client

  The easiest approach is to delegate to the default client and override only what
  you need. For example, to disable gzip compression:

      defmodule MyApp.PostHogClient do
        @behaviour PostHog.API.Client

        @impl true
        def client(api_key, api_host) do
          default = PostHog.API.Client.client(api_key, api_host)
          # Remove the compress_body step added by the default client
          custom = Req.merge(default.client, compress_body: false)
          %{default | client: custom}
        end

        @impl true
        defdelegate request(client, method, url, opts), to: PostHog.API.Client
      end

  ### Adding custom request headers

      defmodule MyApp.PostHogClient do
        @behaviour PostHog.API.Client

        @impl true
        def client(api_key, api_host) do
          default = PostHog.API.Client.client(api_key, api_host)
          custom = Req.merge(default.client, headers: [{"x-custom-header", "value"}])
          %{default | client: custom}
        end

        @impl true
        defdelegate request(client, method, url, opts), to: PostHog.API.Client
      end

  ### Using a different HTTP library

  You can skip `Req` entirely and use any HTTP client. The `client` term you return
  is opaque — it's passed back to your `request/4` callback as-is.

  NOTE: The code below is not guaranteed to be correct or complete — it's just illustrative of the general approach.

      defmodule MyApp.FinchPostHogClient do
        @behaviour PostHog.API.Client

        @impl true
        def client(api_key, api_host) do
          %PostHog.API.Client{
            client: %{api_key: api_key, api_host: api_host},
            module: __MODULE__
          }
        end

        @impl true
        def request(client, method, url, opts) do
          body = opts[:json] |> Map.put_new(:api_key, client.api_key) |> Jason.encode!()

          Finch.build(method, client.api_host <> url, [{"content-type", "application/json"}], body)
          |> Finch.request(MyApp.Finch)
          |> case do
            {:ok, %Finch.Response{status: status, body: body}} ->
              {:ok, %{status: status, body: Jason.decode!(body)}}

            {:error, exception} ->
              {:error, exception}
          end
        end
      end
  """
  @behaviour __MODULE__

  defstruct [:client, :module]

  @type t() :: %__MODULE__{
          client: client(),
          module: atom()
        }
  @typedoc """
  Arbitrary term that is passed as the first argument to the `c:request/4` callback.

  For the default client, this is a `t:Req.Request.t/0` struct.
  """
  @type client() :: any()
  @type response() :: {:ok, %{status: non_neg_integer(), body: any()}} | {:error, Exception.t()}

  @doc """
  Creates a struct that encapsulates all information required for making requests to PostHog's public endpoints.
  """
  @callback client(api_key :: String.t(), cloud :: String.t()) :: t()

  @doc """
  Sends an API request.

  Things such as the API token are expected to be baked into the `client` argument.
  """
  @callback request(client :: client(), method :: atom(), url :: String.t(), opts :: keyword()) ::
              response()

  @impl __MODULE__
  def client(api_key, api_host) do
    client =
      Req.new(base_url: api_host, retry: :transient, compress_body: true)
      |> Req.Request.put_private(:api_key, api_key)

    %__MODULE__{client: client, module: __MODULE__}
  end

  @impl __MODULE__
  def request(client, method, url, opts) do
    client
    |> Req.merge(
      method: method,
      url: url
    )
    |> Req.merge(opts)
    |> then(fn req ->
      req
      |> Req.Request.fetch_option(:json)
      |> case do
        {:ok, json} ->
          api_key = Req.Request.get_private(req, :api_key)
          Req.merge(req, json: Map.put_new(json, :api_key, api_key))

        :error ->
          req
      end
    end)
    |> Req.request()
  end
end
