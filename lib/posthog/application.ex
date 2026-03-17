defmodule PostHog.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    {conv_config, supervisor_config} = PostHog.Config.read!()

    children =
      if conv_config.enable do
        if conv_config.enable_error_tracking do
          :logger.add_handler(:posthog, PostHog.Handler, %{config: supervisor_config})
        end

        [{PostHog.Supervisor, supervisor_config}]
      else
        []
      end

    ownership_children =
      if conv_config.test_mode do
        [{NimbleOwnership, name: PostHog.Ownership}]
      else
        []
      end

    Supervisor.start_link(children ++ ownership_children,
      strategy: :one_for_one,
      name: __MODULE__
    )
  end
end
