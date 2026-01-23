defmodule SdkComplianceAdapter.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    port = System.get_env("PORT", "8080") |> String.to_integer()

    children = [
      SdkComplianceAdapter.State,
      {DynamicSupervisor, strategy: :one_for_one, name: SdkComplianceAdapter.DynamicSupervisor},
      {Plug.Cowboy, scheme: :http, plug: SdkComplianceAdapter.Router, options: [port: port]}
    ]

    opts = [strategy: :one_for_one, name: SdkComplianceAdapter.Supervisor]

    IO.puts("Starting PostHog Elixir SDK adapter on port #{port}")

    Supervisor.start_link(children, opts)
  end
end
