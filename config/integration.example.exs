import Config

config :posthog, :integration_config,
  public_url: "https://us.i.posthog.com",
  api_key: "phc_mykey",
  metadata: [:extra],
  capture_level: :info,
  in_app_otp_apps: [:logger_handler_kit]
