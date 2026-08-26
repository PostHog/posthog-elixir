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

  test "validate normalizes local evaluation configuration" do
    expect(PostHog.API.Mock, :client, 2, fn _api_key, _api_host ->
      %PostHog.API.Client{client: :stub_client, module: PostHog.API.Mock}
    end)

    assert {:ok, config} =
             PostHog.Config.validate(
               api_key: "project_api_key",
               secret_key: "  secret-key  ",
               api_client_module: PostHog.API.Mock
             )

    assert %PostHog.Config.Secret{} = config.secret_key
    assert PostHog.Config.Secret.reveal(config.secret_key) == "secret-key"
    refute inspect(config) =~ "secret-key"
    assert inspect(config) =~ "#PostHog.Config.Secret<redacted>"
    assert config.enable_local_evaluation
    assert config.feature_flags_poll_interval_ms == 30_000
    assert config.flag_definition_cache_provider == nil
    assert config.flag_definition_cache_provider_timeout_ms == 5_000
    assert config.flag_definition_request_timeout_ms == 10_000

    assert {:ok, blank} =
             PostHog.Config.validate(
               api_key: "project_api_key",
               secret_key: "  ",
               api_client_module: PostHog.API.Mock
             )

    assert blank.secret_key == nil
  end

  test "validate defaults a missing api_host" do
    expect(PostHog.API.Mock, :client, fn api_key, api_host ->
      assert api_key == "project_api_key"
      assert api_host == "https://us.i.posthog.com"

      %PostHog.API.Client{client: :stub_client, module: PostHog.API.Mock}
    end)

    assert {:ok, config} =
             PostHog.Config.validate(
               api_key: "project_api_key",
               api_client_module: PostHog.API.Mock
             )

    assert config.api_host == "https://us.i.posthog.com"
  end

  test "validate applies feature flag retry count to the api client" do
    expect(PostHog.API.Mock, :client, fn _api_key, _api_host ->
      %PostHog.API.Client{client: :stub_client, module: PostHog.API.Mock}
    end)

    assert {:ok, config} =
             PostHog.Config.validate(
               api_key: "project_api_key",
               api_client_module: PostHog.API.Mock,
               feature_flags_request_max_retries: 0
             )

    assert config.api_client.feature_flags_request_max_retries == 0
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

  for {label, api_key_option} <- [
        {"missing", []},
        {"nil", [api_key: nil]},
        {"empty", [api_key: ""]},
        {"blank after trimming whitespace", [api_key: " \n\t "]}
      ] do
    test "validate disables PostHog when api_key is #{label}" do
      log =
        capture_log(fn ->
          options = unquote(Macro.escape(api_key_option)) ++ [api_client_module: PostHog.API.Mock]

          assert {:ok, config} = PostHog.Config.validate(options)

          assert config.api_key == ""
          assert config.api_host == "https://us.i.posthog.com"
          assert config.enabled == false
          assert config.api_client == nil
        end)

      assert log =~
               "posthog api_key is empty after trimming whitespace; PostHog will start in disabled/no-op mode"
    end
  end
end
