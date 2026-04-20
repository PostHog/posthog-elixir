defmodule PostHog.ConfigTest do
  use ExUnit.Case, async: true

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

  test "validate rejects an api_key that is blank after trimming whitespace" do
    assert {:error, error} =
             PostHog.Config.validate(
               api_key: " \n\t ",
               api_host: "https://us.i.posthog.com",
               api_client_module: PostHog.API.Mock
             )

    assert Exception.message(error) =~ "api_key"
    assert Exception.message(error) =~ "cannot be blank after trimming whitespace"
  end
end
