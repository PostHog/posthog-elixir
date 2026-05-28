# PostHog Elixir SDK

[![Hex.pm](https://img.shields.io/hexpm/v/posthog.svg)](https://hex.pm/packages/posthog)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/posthog)

A powerful Elixir SDK for [PostHog](https://posthog.com)

## Features

- Analytics and Feature Flags support
- Error tracking support
- Powerful process-based context propagation
- Asynchronous event sending with built-in batching
- Overridable HTTP client
- Support for multiple PostHog projects

## Getting Started

Add `PostHog` to your dependencies:

```elixir
def deps do
  [
    {:posthog, "~> 2.0"}
  ]
end
```

Configure the `PostHog` application environment:

```elixir
config :posthog,
  enable: true,
  enable_error_tracking: true,
  api_host: "https://us.i.posthog.com", # Or `https://eu.i.posthog.com` or your self-hosted PostHog instance URL
  api_key: "phc_my_api_key",
  in_app_otp_apps: [:my_app]
```

For test environment, you want to enable test_mode:

```elixir
config :posthog,
  test_mode: true
```

Optionally, enable [Plug integration](lib/posthog/integrations/plug.ex).

You're all set! 🎉 For more information on configuration, check the `PostHog.Config` module
documentation and the [advanced configuration guide](guides/advanced-configuration.md).

## Capturing Events

To capture an event, use `PostHog.capture/2`:

```elixir
iex> PostHog.capture("user_signed_up", %{distinct_id: "distinct_id_of_the_user"})
```

You can pass additional properties in the last argument:

```elixir
iex> PostHog.capture("user_signed_up", %{
  distinct_id: "distinct_id_of_the_user",
  login_type: "email",
  is_free_trial: true
})
```

## Special Events

`PostHog.capture/2` is very powerful and allows you to send events that have
special meaning. For example:

### Create Alias

```elixir
iex> PostHog.capture("$create_alias", %{distinct_id: "frontend_id", alias: "backend_id"})
```

### Group Analytics

```elixir
iex> PostHog.capture("$groupidentify", %{
  distinct_id: "static_string_used_for_all_group_events",
  "$group_type": "company",
  "$group_key": "company_id_in_your_db"
})
```

## Context

Carrying `distinct_id` around all the time might not be the most convenient
approach, so `PostHog` lets you store it and other properties in a _context_.
The context is stored in the `Logger` metadata, and PostHog will automatically
attach these properties to any events you capture with `PostHog.capture/3`, as long as they
happen in the same process.

```elixir
iex> PostHog.set_context(%{distinct_id: "distinct_id_of_the_user"})
iex> PostHog.capture("page_opened")
```

You can scope context by event name. In this case, it will only be attached to a specific event:

```elixir
iex> PostHog.set_event_context("sensitive_event", %{"$process_person_profile": false})
```

You can always inspect the context:

```elixir
iex> PostHog.get_context()
%{distinct_id: "distinct_id_of_the_user"}
iex> PostHog.get_event_context("sensitive_event")
%{distinct_id: "distinct_id_of_the_user", "$process_person_profile": false}
```

## Feature Flags

Evaluate feature flags once for a user with `PostHog.FeatureFlags.evaluate_flags/1`,
then read values from the returned snapshot.

```elixir
# Boolean feature flag
{:ok, snapshot} = PostHog.FeatureFlags.evaluate_flags("user123")
if PostHog.FeatureFlags.Evaluations.enabled?(snapshot, "new-dashboard") do
  # Do something differently for this user
end

# Multivariate feature flag
case PostHog.FeatureFlags.Evaluations.get_flag(snapshot, "checkout-flow") do
  "variant-a" -> :variant_a
  true -> :enabled_boolean_flag
  false -> :disabled
  nil -> :not_returned
end

# Optional payload
payload = PostHog.FeatureFlags.Evaluations.get_flag_payload(snapshot, "checkout-flow")
```

`get_flag/2` returns the variant string for multivariate flags, `true` for enabled
boolean flags, `false` for disabled flags, and `nil` when the flag was not returned
by the evaluation.

### Include feature flag information when capturing events

If you want to break down or filter captured events by feature flag value, put the
same snapshot in the process context before capturing events:

```elixir
{:ok, snapshot} = PostHog.FeatureFlags.evaluate_flags("user123")

if PostHog.FeatureFlags.Evaluations.enabled?(snapshot, "new-dashboard") do
  # Do something differently for this user
end

PostHog.FeatureFlags.set_in_context(snapshot)
PostHog.capture("page_viewed", %{distinct_id: "user123"})
```

This attaches `$feature/<flag-key>` properties and `$active_feature_flags` without
making another `/flags` request. To reduce event property bloat, filter the
snapshot first:

```elixir
# Attach only flags accessed with enabled?/2 or get_flag/2
PostHog.FeatureFlags.set_in_context(
  PostHog.FeatureFlags.Evaluations.only_accessed(snapshot)
)

# Or attach only specific flags
PostHog.FeatureFlags.set_in_context(
  PostHog.FeatureFlags.Evaluations.only(snapshot, ["checkout-flow", "new-dashboard"])
)
```

### Evaluating only specific flags

By default, `evaluate_flags/1` evaluates every flag for the user. If you only need
a few flags, pass `:flag_keys` to request only those flags:

```elixir
{:ok, snapshot} =
  PostHog.FeatureFlags.evaluate_flags(%{
    distinct_id: "user123",
    flag_keys: ["checkout-flow", "new-dashboard"]
  })
```

> #### Deprecated feature flag helpers {: .warning}
>
> `PostHog.FeatureFlags.check/2`, `PostHog.FeatureFlags.check!/2`,
> `PostHog.FeatureFlags.get_feature_flag_result/2`, and
> `PostHog.FeatureFlags.get_feature_flag_result!/2` still work during the
> migration period, but prefer `evaluate_flags/1` for new code.

## Error Tracking

Error Tracking is enabled by default.

![](assets/error-tracking-screenshot.png)

You can always disable it by setting `enable_error_tracking` to false:

```elixir
config :posthog, enable_error_tracking: false
```

## Custom HTTP Client

The SDK uses [Req](https://hexdocs.pm/req) under the hood with gzip compression and
transient retry enabled by default. You can swap in your own HTTP client module to
change any of this behaviour — disable compression, add custom headers, attach
telemetry, or use a completely different HTTP library.

Set the `api_client_module` config option to a module that implements the
`PostHog.API.Client` behaviour:

```elixir
config :posthog, api_client_module: MyApp.PostHogClient
```

The simplest approach is to wrap the default client and override only what you need:

```elixir
defmodule MyApp.PostHogClient do
  @behaviour PostHog.API.Client

  @impl true
  def client(api_key, api_host) do
    default = PostHog.API.Client.client(api_key, api_host)

    # Disable gzip compression
    custom = Req.merge(default.client, compress_body: false)

    %{default | client: custom}
  end

  @impl true
  defdelegate request(client, method, url, opts), to: PostHog.API.Client
end
```

See `PostHog.API.Client` docs for more examples, including adding custom headers
and using a different HTTP library entirely.

## Multiple PostHog Projects

If your app works with multiple PostHog projects, PostHog can accommodate you. For
setup instructions, consult the [advanced configuration guide](guides/advanced-configuration.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for local setup, integration test, and pull request guidelines.
