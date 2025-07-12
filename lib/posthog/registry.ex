defmodule PostHog.Registry do
  @moduledoc false
  def config(supervisor_name) do
    {:ok, config} =
      supervisor_name
      |> registry_name()
      |> Registry.meta(:config)

    config
  end

  def registry_name(supervisor_name), do: Module.concat(supervisor_name, Registry)

  def via(supervisor_name, server_name),
    do: {:via, Registry, {registry_name(supervisor_name), server_name}}
end
