import Config

config :posthog, :integration_config,
  public_url: "https://us.i.posthog.com",
  api_key: "phc_tEQ8UGRHdPBaT42yocd714aoiW4mBkmx6nTNrxjqLpf",
  metadata: [:extra],
  capture_level: :info,
  in_app_otp_apps: [:logger_handler_kit]
