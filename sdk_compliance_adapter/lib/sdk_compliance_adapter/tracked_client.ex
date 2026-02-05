defmodule SdkComplianceAdapter.TrackedClient do
  @moduledoc """
  A custom API client that tracks requests for test assertions.

  This client wraps the default PostHog.API.Client and intercepts requests
  to record them in the adapter state.
  """
  @behaviour PostHog.API.Client

  @impl true
  def client(api_key, api_host) do
    # Create the underlying Req client
    client =
      Req.new(base_url: api_host)
      |> Req.Request.put_private(:api_key, api_key)

    # Return the standard PostHog.API.Client struct with our module
    %PostHog.API.Client{client: client, module: __MODULE__}
  end

  @impl true
  def request(client, method, url, opts) do
    # Build the request
    req =
      client
      |> Req.merge(method: method, url: url)
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

    # Extract UUIDs from the batch before sending
    uuid_list = extract_uuids(opts)
    event_count = count_events(opts)

    # Make the request
    result = Req.request(req)

    # Track the request
    case result do
      {:ok, %{status: status}} ->
        SdkComplianceAdapter.State.record_request(status, event_count, uuid_list)

      {:error, reason} ->
        SdkComplianceAdapter.State.set_last_error(inspect(reason))
    end

    result
  end

  defp extract_uuids(opts) do
    case Keyword.get(opts, :json) do
      %{batch: batch} when is_list(batch) ->
        Enum.map(batch, fn event ->
          # Check event level first, then properties
          Map.get(event, :uuid) ||
            Map.get(event, "uuid") ||
            get_in(event, [:properties, :uuid]) ||
            get_in(event, ["properties", "uuid"])
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp count_events(opts) do
    case Keyword.get(opts, :json) do
      %{batch: batch} when is_list(batch) -> length(batch)
      _ -> 0
    end
  end
end
