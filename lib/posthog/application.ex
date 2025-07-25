defmodule PostHog.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    children =
      case PostHog.Config.read!() do
        {%{enable: true, enable_error_tracking: error_tracking}, config} ->
          if error_tracking do
            :logger.add_handler(:posthog, PostHog.Handler, %{config: config})
          end

          [{PostHog.Supervisor, config}]

        _ ->
          []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
