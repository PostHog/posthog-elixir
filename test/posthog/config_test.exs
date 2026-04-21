defmodule PostHog.ConfigTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mox

  setup :verify_on_exit!

  test "validate trims whitespace-sensitive config values before building the client" do
    expect(PostHog.API.Mock, :client, fn api_key, api_host ->
      assert api_key == "project_api_key"
      assert api_host == "https://eu.i.posthog.com"

      %PostHog.API.Client{client: :stub_client, module: PostHog.API.Mock}
    end)

    assert {:ok, config} =
             PostHog.Config.validate(
               api_key: " \nproject_api_key\t ",
               api_host: " \nhttps://eu.i.posthog.com\t ",
               api_client_module: PostHog.API.Mock
             )

    assert config.api_key == "project_api_key"
    assert config.api_host == "https://eu.i.posthog.com"
  end

  test "validate defaults a blank api_host after trimming whitespace" do
    expect(PostHog.API.Mock, :client, fn api_key, api_host ->
      assert api_key == "project_api_key"
      assert api_host == "https://us.i.posthog.com"

      %PostHog.API.Client{client: :stub_client, module: PostHog.API.Mock}
    end)

    assert {:ok, config} =
             PostHog.Config.validate(
               api_key: "project_api_key",
               api_host: " \n\t ",
               api_client_module: PostHog.API.Mock
             )

    assert config.api_host == "https://us.i.posthog.com"
  end

  test "validate logs when api_key is blank after trimming whitespace" do
    expect(PostHog.API.Mock, :client, fn api_key, api_host ->
      assert api_key == ""
      assert api_host == "https://us.i.posthog.com"

      %PostHog.API.Client{client: :stub_client, module: PostHog.API.Mock}
    end)

    log =
      capture_log(fn ->
        assert {:ok, config} =
                 PostHog.Config.validate(
                   api_key: " \n\t ",
                   api_host: "https://us.i.posthog.com",
                   api_client_module: PostHog.API.Mock
                 )

        assert config.api_key == ""
      end)

    assert log =~ "posthog api_key is empty after trimming whitespace; check your project API key"
  end
end
