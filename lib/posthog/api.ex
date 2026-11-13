defmodule PostHog.API do
  @moduledoc false

  alias PostHog.Config.Secret

  def batch(%__MODULE__.Client{} = client, batch) do
    client.module.request(client.client, :post, "/batch", json: %{batch: batch})
  end

  def flags(%__MODULE__.Client{} = client, event) do
    client.module.request(client.client, :post, "/flags",
      json: event,
      params: %{v: 2},
      retry: &__MODULE__.Client.retry_flags_request?/2,
      retry_delay: &__MODULE__.Client.flags_retry_delay/1,
      max_retries: client.feature_flags_request_max_retries
    )
  end

  def flag_definitions(
        %__MODULE__.Client{} = client,
        project_api_key,
        %PostHog.Config.Secret{} = secret_key,
        etag
      ) do
    headers =
      [{"authorization", "Bearer #{PostHog.Config.Secret.reveal(secret_key)}"}]
      |> then(fn headers ->
        if is_binary(etag), do: [{"if-none-match", etag} | headers], else: headers
      end)

    client.module.request(client.client, :get, "/flags/definitions",
      params: %{token: project_api_key, send_cohorts: true},
      headers: headers
    )
  end

  def remote_config_payload(
        %__MODULE__.Client{} = client,
        project_api_key,
        %Secret{} = secret_key,
        flag_key
      ) do
    path =
      "/api/projects/@current/feature_flags/" <>
        URI.encode(flag_key, &URI.char_unreserved?/1) <> "/remote_config"

    opts = [
      params: %{token: project_api_key},
      headers: [{"authorization", "Bearer #{Secret.reveal(secret_key)}"}],
      retry: false
    ]

    # Req would otherwise decode JSON bodies, hiding whether the body was valid JSON.
    # A custom client returns a decoded body, so only the default client is asked for raw bytes.
    {opts, body_format} =
      if client.module == __MODULE__.Client,
        do: {Keyword.put(opts, :decode_body, false), :raw},
        else: {opts, :decoded}

    with {:ok, response} <- client.module.request(client.client, :get, path, opts) do
      {:ok, response, body_format}
    end
  end
end
