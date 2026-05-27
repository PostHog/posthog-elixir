import Config

config :posthog, enable: false, mode: :test

if File.exists?("config/integration.exs"), do: import_config("integration.exs")
