defmodule PostHog.API do
  @moduledoc false
  def post_batch(%__MODULE__.Client{} = client, batch) do
    client.module.request(client.client, :post, "/batch", json: %{batch: batch})
  end

  def flags(%__MODULE__.Client{} = client, event) do
    client.module.request(client.client, :post, "/flags", json: event, params: %{v: 2})
  end
end
