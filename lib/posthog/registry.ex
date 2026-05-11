defmodule PostHog.Registry do
  @moduledoc false
  def config(supervisor_name) do
    {:ok, config} =
      supervisor_name
      |> registry_name()
      |> Registry.meta(:config)

    config
  rescue
    e in ArgumentError ->
      if supervisor_name == PostHog do
        {conv_config, _} = PostHog.Config.read!()

        if !conv_config.enable do
          raise PostHog.Error, """
          PostHog default supervisor isn't started. Make sure to set `enable: true` configuration option.

          If you're running PostHog supervisor under your own supervision tree, you must specify PostHog supervisor name explicitely, e.g.:

              PostHog.capture(MyPostHog, "event_name", %{distinct_id: "123"})
          """
        end
      end

      raise e
  end

  def registry_name(supervisor_name), do: Module.concat(supervisor_name, Registry)

  def via(supervisor_name, server_name),
    do: {:via, Registry, {registry_name(supervisor_name), server_name}}

  def via(supervisor_name, pool_name, index),
    do: {:via, Registry, {registry_name(supervisor_name), {pool_name, index}}}
end
