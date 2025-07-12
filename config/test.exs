import Config

config :posthog, enable: false

if File.exists?("config/integration.exs"), do: import_config("integration.exs")
