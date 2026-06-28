defmodule PostHog.API.ClientTest do
  use ExUnit.Case, async: true

  alias PostHog.API.Client

  test "client/2 sets the posthog-elixir User-Agent" do
    %Client{client: req} = Client.client("phc_test", "https://us.i.posthog.com")

    assert req.headers["user-agent"] == [Client.user_agent()]
  end

  test "flags retry policy retries transport errors but not HTTP responses" do
    assert Client.retry_flags_request?(%Req.Request{}, %Req.TransportError{reason: :timeout})
    assert Client.retry_flags_request?(%Req.Request{}, %Req.HTTPError{reason: :closed})
    refute Client.retry_flags_request?(%Req.Request{}, %Req.Response{status: 503})
  end

  test "flags retry delay starts at 300ms and doubles" do
    assert Client.flags_retry_delay(0) == 300
    assert Client.flags_retry_delay(1) == 600
    assert Client.flags_retry_delay(2) == 1200
  end
end
