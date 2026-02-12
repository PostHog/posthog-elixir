defmodule SdkComplianceAdapter.TrackedClient do
  @moduledoc """
  A custom API client that tracks requests for test assertions.

  This client wraps the default PostHog.API.Client and intercepts requests
  to record them in the adapter state.
  """
  @behaviour PostHog.API.Client

  @impl true
  def client(api_key, api_host) do
    client = PostHog.API.Client.client(api_key, api_host)
    instrumented_client = 
      client.client
      |> Req.Request.append_response_steps(track: &track/1)
      |> Req.Request.append_error_steps(track_error: &track_error/1)
      
    %{client | client: instrumented_client}
  end
  
  @impl true
  defdelegate request(client, method, url, opts), to: PostHog.API.Client 
  
  def track({request, response}) do
    req_body =
      request.body
      |> to_string()
      |> decompress(request)
      |> JSON.decode!()

    uuid_list = extract_uuids(req_body)
    event_count = count_events(req_body)
    
    SdkComplianceAdapter.State.record_request(response.status, event_count, uuid_list)
    
    {request, response}
  end
  
  def track_error({request, exception}) do
    SdkComplianceAdapter.State.set_last_error(inspect(exception))
    {request, exception}
  end

  defp decompress(body, request) do
    case Req.Request.get_header(request, "content-encoding") do
      ["gzip"] -> :zlib.gunzip(body)
      _ -> body
    end
  end

  defp extract_uuids(request) do
    request
    |> get_in([Access.key("batch", []), Access.all(), "uuid"])
    |> Enum.reject(&is_nil/1)
  end

  defp count_events(%{"batch" => events}) when is_list(events), do: length(events)
  defp count_events(_), do: 0
end
