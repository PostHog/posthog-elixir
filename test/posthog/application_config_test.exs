defmodule PostHog.ApplicationConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  setup :verify_on_exit!

  setup do
    previous_env = Application.get_all_env(:posthog)

    on_exit(fn ->
      :posthog
      |> Application.get_all_env()
      |> Keyword.keys()
      |> Enum.each(&Application.delete_env(:posthog, &1))

      Enum.each(previous_env, fn {key, value} ->
        Application.put_env(:posthog, key, value)
      end)
    end)
  end

  test "read! does not raise when enabled and api_key is missing" do
    Application.put_env(:posthog, :enable, true)
    Application.put_env(:posthog, :api_client_module, PostHog.API.Mock)
    Application.delete_env(:posthog, :api_key)
    Application.delete_env(:posthog, :api_host)

    log =
      capture_log(fn ->
        assert {%{enable: true}, %{api_key: "", enabled: false, api_client: nil} = config} =
                 PostHog.Config.read!()

        assert config.api_host == "https://us.i.posthog.com"
      end)

    assert log =~
             "posthog api_key is empty after trimming whitespace; PostHog will start in disabled/no-op mode"
  end
end
