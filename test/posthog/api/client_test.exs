defmodule PostHog.API.ClientTest do
  use ExUnit.Case, async: true

  test "client/2 sets the posthog-elixir User-Agent" do
    %PostHog.API.Client{client: req} =
      PostHog.API.Client.client("phc_test", "https://us.i.posthog.com")

    version = Mix.Project.config()[:version]
    assert req.headers["user-agent"] == ["posthog-elixir/#{version}"]
  end
end
