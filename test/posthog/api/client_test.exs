defmodule PostHog.API.ClientTest do
  use ExUnit.Case, async: true

  alias PostHog.API.Client

  test "client/2 sets the posthog-elixir User-Agent" do
    %Client{client: req} = Client.client("phc_test", "https://us.i.posthog.com")

    assert req.headers["user-agent"] == [Client.user_agent()]
  end

  for {case_name, response_or_exception, expected} <- [
        {"transport timeout", %Req.TransportError{reason: :timeout}, true},
        {"transport closed", %Req.TransportError{reason: :closed}, true},
        {"http error", %Req.HTTPError{reason: :closed}, false},
        {"http status response", %Req.Response{status: 503}, false}
      ] do
    test "flags retry policy handles #{case_name}" do
      assert Client.retry_flags_request?(
               %Req.Request{},
               unquote(Macro.escape(response_or_exception))
             ) == unquote(expected)
    end
  end

  for {retry_count, expected_delay} <- [{0, 300}, {1, 600}, {2, 1200}] do
    test "flags retry delay for retry count #{retry_count}" do
      assert Client.flags_retry_delay(unquote(retry_count)) == unquote(expected_delay)
    end
  end
end
