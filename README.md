# PostHog Elixir Client

[![Hex.pm](https://img.shields.io/hexpm/v/posthog.svg)](https://hex.pm/packages/posthog)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/posthog)

A powerful Elixir client for [PostHog](https://posthog.com), providing seamless integration with PostHog's analytics and feature flag APIs.

## Features

- Event Capture: Track user actions and custom events
- Feature Flags: Manage feature flags and multivariate tests
- Batch Processing: Send multiple events efficiently
- Custom Properties: Support for user, group, and person properties
- Flexible Configuration: Customizable JSON library and API version
- Environment Control: Disable tracking in development/test environments
- Configurable HTTP Client: Customizable timeouts, retries, and HTTP client implementation

## Installation

Add `posthog` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:posthog, "~> 1.0"}
  ]
end
```

## Configuration

Add your PostHog configuration to your application's config:

```elixir
# config/config.exs
config :posthog,
  api_url: "https://us.posthog.com",  # Or `https://eu.posthog.com` or your self-hosted PostHog instance URL
  api_key: "phc_your_project_api_key"

# Optional configurations
config :posthog,
  json_library: Jason,   # Default JSON parser (optional)
  capture_enabled: true, # Whether to enable PostHog tracking (optional, defaults to true)
  http_client: Posthog.HTTPClient.Hackney,  # Default HTTP client (optional)
  http_client_opts: [    # HTTP client options (optional)
    timeout: 5_000,      # Request timeout in milliseconds (default: 5_000)
    retries: 3,          # Number of retries on failure (default: 3)
    retry_delay: 1_000   # Delay between retries in milliseconds (default: 1_000)
  ]
```

### HTTP Client Configuration

The library uses Hackney as the default HTTP client, but you can configure its behavior or even swap it for a different implementation by simply implementing the `Posthog.HTTPClient` behavior:

```elixir
# config/config.exs
config :posthog,
  # Use a different HTTP client implementation
  http_client: MyCustomHTTPClient,

  # Configure HTTP client options
  http_client_opts: [
    timeout: 10_000,   # 10 seconds timeout
    retries: 5,        # 5 retries
    retry_delay: 2_000 # 2 seconds between retries
  ]
```

For testing, you might want to use a mock HTTP client:

```elixir
# test/support/mocks.ex
defmodule Posthog.HTTPClient.Test do
  @behaviour Posthog.HTTPClient

  def post(url, body, headers, _opts) do
    # Return mock responses for testing
    {:ok, %{status: 200, headers: [], body: %{}}}
  end
end

# config/test.exs
config :posthog,
  http_client: Posthog.HTTPClient.Test
```

### Disabling PostHog capture

You can disable PostHog tracking by setting `enabled_capture: false` in your configuration. This is particularly useful in development or test environments where you don't want to send actual events to PostHog.

When `enabled_capture` is set to `false`:

- All `Posthog.capture/3` and `Posthog.batch/2` calls will succeed silently
- PostHog will still communicate with the server for Feature Flags

This is useful for:

- Development and test environments where you don't want to pollute your PostHog instance
- Situations where you need to temporarily disable tracking

Example configuration for development:

```elixir
# config/dev.exs
config :posthog,
  enabled_capture: false  # Disable tracking in development
```

Example configuration for test:

```elixir
# config/test.exs
config :posthog,
  enabled_capture: false  # Disable tracking in test environment
```

## Usage

### Capturing Events

Simple event capture:

```elixir
# Basic event with `event` and `distinct_id`, both required
Posthog.capture("page_view", "user_123")

# Event with properties
Posthog.capture("purchase", "user_123", %{
    product_id: "prod_123",
    price: 99.99,
    currency: "USD"
})

# Event with custom timestamp
Posthog.capture("signup_completed", "user_123", %{}, timestamp: DateTime.utc_now())

# Event with custom UUID
uuid = "..."
Posthog.capture("signup_completed", "user_123", %{}, uuid: uuid)

# Event with custom headers
Posthog.capture(
  "login",
  "user_123",
  %{},
  headers: [{"x-forwarded-for", "127.0.0.1"}]
)
```

### Batch Processing

Send multiple events in a single request:

```elixir
events = [
  {"page_view", "user_123", %{}},
  {"button_click", "user_123", %{button_id: "signup"}}
]

Posthog.batch(events)
```

### Feature Flags

Get all feature flags for a user:

```elixir
{:ok, flags} = Posthog.feature_flags("user_123")

# Response format:
# %{
#   "featureFlags" => %{"flag-1" => true, "flag-2" => "variant-b"},
#   "featureFlagPayloads" => %{
#     "flag-1" => true,
#     "flag-2" => %{"color" => "blue", "size" => "large"}
#   }
# }
```

Check specific feature flag:

```elixir
# Boolean feature flag
{:ok, flag} = Posthog.feature_flag("new-dashboard", "user_123")
# Returns: %Posthog.FeatureFlag{name: "new-dashboard", payload: true, enabled: true}

# Multivariate feature flag
{:ok, flag} = Posthog.feature_flag("pricing-test", "user_123")
# Returns: %Posthog.FeatureFlag{
#   name: "pricing-test",
#   payload: %{"price" => 99, "period" => "monthly"},
#   enabled: "variant-a"
# }

# Quick boolean check
if Posthog.feature_flag_enabled?("new-dashboard", "user_123") do
  # Show new dashboard
end
```

Feature flags with group properties:

```elixir
Posthog.feature_flags("user_123",
  groups: %{company: "company_123"},
  group_properties: %{company: %{industry: "tech"}},
  person_properties: %{email: "user@example.com"}
)
```

#### Stop sending `$feature_flag_called`

We automatically send `$feature_flag_called` events so that you can properly keep track of which feature flags you're accessing via `Posthog.feature_flag()` calls. If you wanna save some events, you can disable this by adding `send_feature_flag_event: false` to the call:

```elixir
# Boolean feature flag
{:ok, flag} = Posthog.feature_flag("new-dashboard", "user_123", send_feature_flag_event: false)
```

## Local Development

Run `bin/setup` to install development dependencies or run the following commands manually:

We recommend using `asdf` to manage Elixir and Erlang versions:

```sh
# Install required versions
asdf install

# Install dependencies
mix deps.get
mix compile
```

Run tests:

```sh
bin/test
```

(This runs `mix test`).

Format code:

```sh
bin/fmt
```

### Troubleshooting

If you encounter WX library issues during Erlang installation:

```sh
# Disable WX during installation
export KERL_CONFIGURE_OPTIONS="--without-wx"
```

To persist this setting, add it to your shell configuration file (`~/.bashrc`, `~/.zshrc`, or `~/.profile`).

## Examples

There's an example console project in `examples/feature_flag_demo` that shows how to use the client. Follow the instructions in [the README](examples/feature_flag_demo/README.md) to run it.

## Development Tools

This project uses several development tools to maintain code quality and security:

### Credo

Credo is a static code analysis tool that helps enforce coding standards and catch potential issues. Run it with:

```bash
mix credo --strict
```

For more detailed output:

```bash
mix credo --strict --verbose
```

### Mix Audit

Mix Audit helps identify security vulnerabilities in dependencies. Run it with:

```bash
mix deps.audit
```

## Contributing

When contributing to this project, please ensure your code passes all the development tool checks:

1. Run Credo to ensure code style consistency
2. Run Mix Audit to check for security vulnerabilities
3. Run Mix Unused to identify any unused code
4. Run the test suite with `mix test`

## License

This project is licensed under the MIT License - see the [LICENSE](./LICENSE) file for details.
