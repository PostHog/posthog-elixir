defmodule PostHog.API do
  @moduledoc false
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
end
