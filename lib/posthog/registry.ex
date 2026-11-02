defmodule PostHog.Registry do
  @moduledoc false
  def config(supervisor_name) do
    registry = registry_name(supervisor_name)

    if Process.whereis(registry) do
      case Registry.meta(registry, :config) do
        {:ok, config} -> config
        :error -> disabled_config(supervisor_name)
      end
    else
      disabled_config(supervisor_name)
    end
  rescue
    ArgumentError -> disabled_config(supervisor_name)
  end

  # The secret key stays out of `config/1`, so it never shows up where the config is read or logged.
  def secret_key(supervisor_name) do
    case Registry.meta(registry_name(supervisor_name), :secret_key) do
      {:ok, secret_key} -> secret_key
      :error -> nil
    end
  rescue
    ArgumentError -> nil
  end

  def disabled_config(supervisor_name) do
    %{
      supervisor_name: supervisor_name,
      enabled: false,
      api_client: nil,
      global_properties: %{},
      before_send: nil,
      test_mode: false
    }
  end

  def registry_name(supervisor_name), do: Module.concat(supervisor_name, Registry)

  def via(supervisor_name, server_name),
    do: {:via, Registry, {registry_name(supervisor_name), server_name}}

  def via(supervisor_name, pool_name, index),
    do: {:via, Registry, {registry_name(supervisor_name), {pool_name, index}}}
end
