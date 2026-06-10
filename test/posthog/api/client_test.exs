defmodule PostHog.API.ClientTest do
  use ExUnit.Case, async: true

  test "client/2 sets the posthog-elixir User-Agent" do
    %PostHog.API.Client{client: req} =
      PostHog.API.Client.client("phc_test", "https://us.i.posthog.com")

    assert req.headers["user-agent"] == [PostHog.API.Client.user_agent()]
  end
end
