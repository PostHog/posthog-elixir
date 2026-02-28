defmodule PostHog.Case do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      import PostHog.Case
      import PostHog.Test, only: [all_captured: 1, all_captured: 0]
    end
  end

  def setup_supervisor(context) do
    Mox.stub_with(PostHog.API.Mock, PostHog.API.Stub)

    config =
      [
        api_host: "https://us.i.posthog.com",
        api_key: "my_api_key",
        api_client_module: PostHog.API.Mock,
        supervisor_name: context[:test],
        capture_level: :info,
        test_mode: true
      ]
      |> Keyword.merge(context[:config] || [])
      |> PostHog.Config.validate!()
      |> Map.put(:max_batch_time_ms, :timer.minutes(1))
      |> Map.put(:max_batch_events, 100)

    start_link_supervised!({PostHog.Supervisor, config})

    sender_pid =
      config.supervisor_name |> PostHog.Registry.via(PostHog.Sender) |> GenServer.whereis()

    context
    |> Map.put(:config, config)
    |> Map.put(:sender_pid, sender_pid)
  end

  def setup_logger_handler(%{config: config} = context) do
    big_config_override =
      context
      |> Map.take([:handle_otp_reports, :handle_sasl_reports, :level])
      |> Map.put(:share_ownership_with, [PostHog.Ownership])

    {context, on_exit} =
      LoggerHandlerKit.Arrange.add_handler(
        context.test,
        PostHog.Handler,
        config,
        big_config_override
      )

    on_exit(on_exit)
    context
  end

  # While PostHog Error Tracking is compatible with pre-1.19 Elixir, some
  # advanced features only work with 1.19+
  def pre_19? do
    System.version()
    |> Version.match?("< 1.19.0")
  end
end
