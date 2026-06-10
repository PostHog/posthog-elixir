defmodule PostHog.Lib do
  @moduledoc false

  @name "posthog-elixir"
  @version Mix.Project.config()[:version]

  def name, do: @name
  def version, do: @version
  def user_agent, do: "#{@name}/#{@version}"
end
