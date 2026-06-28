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
end
