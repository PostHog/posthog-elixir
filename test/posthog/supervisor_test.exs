defmodule PostHog.SupervisorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @supervisor_name __MODULE__

  test "disabled config starts without senders and captures as no-op" do
    {config, _log} =
      with_log(fn ->
        PostHog.Config.validate!(
          api_key: " \n\t ",
          api_host: "https://us.i.posthog.com",
          supervisor_name: @supervisor_name
        )
      end)

    start_link_supervised!({PostHog.Supervisor, config})

    assert [] =
             @supervisor_name
             |> PostHog.Registry.registry_name()
             |> Registry.select([{{{PostHog.Sender, :_}, :"$1", :"$2"}, [], [:"$1"]}])

    assert :ok = PostHog.bare_capture(@supervisor_name, "disabled capture", "distinct_id", %{})
  end
end
