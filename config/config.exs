import Config

if config_env() == :test do
  config :posthog, api_key: "phc_yeluS6373YhTTtwXEhRZ5vEHKyVIsTkm2HGtEwbMr4D", api_url: "https://app.posthog.com"
end
