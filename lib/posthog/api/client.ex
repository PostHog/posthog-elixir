defmodule PostHog.API.Client do
  @moduledoc """
  Behaviour and the default implementation of a PostHog API client. Uses `Req`.

  Users are unlikely to interact with this module directly, but here's an
  example just in case:

  ## Example

      > client = PostHog.API.Client.client("phc_abcdedfgh", "https://us.i.posthog.com")
      %PostHog.API.Client{
        client: %Req.Request{...},
        module: PostHog.API.Client
      }

      > client.module.request(client.client, :post, "/flags", json: %{distinct_id: "user123"}, params: %{v: 2, config: true})
      {:ok, %Req.Response{status: 200, body: %{...}}}
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
      Req.new(base_url: api_host, retry: :transient)
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
