# Migration

This is a migration guide for all major version bumps

## v1 -> v2

Version 2.0 is a whole new library, so we encourage you to use this upgrade as
an opportunity to revisit your PostHog usage in your application. Even the root
level module was renamed from `Posthog` to `PostHog`.

### Configuration

Configuration has been completely reworked. We advise you to remove your
existing configuration and follow [Getting Started](README.md#getting-started)
section for setup.

### Event Capture

`PostHog.capture` signature has changed. It now accepts properties only as a
map. `distinct_id` is now included in the properties.

```elixir
PostHog.capture("user_signed_up", %{
  distinct_id: "distinct_id_of_the_user",
  login_type: "email",
  is_free_trial: true
})
```

No additional options can be passed. PostHog now automatically offloads events to a
pool of sender workers that will batch and send your events. This also means
that `Posthog.batch` doesn't exist anymore and you should simply call `capture/2` for each of your events.

### Feature Flags

`Posthog.feature_flag` and `Posthog.feature_flag_enabled` functions were
replaced with `PostHog.FeatureFlags` module. Check its docs for the new usage
guidelines.

## v0 -> v1

When we stabilized our library, we decided to pull some breaking changes.

### Minimum Elixir version bumped to v1.14

The library previously supported Elixir v1.12+. You'll need to migrate to Elixir v1.14 - at least. Elixir v1.14 was launched more than 2.5 years ago, and we believe that should be enough time for you to migrate. You can check Elixir's own release announcements to understand how you should proceed with the migration.

- https://elixir-lang.org/blog/2021/12/03/elixir-v1-13-0-released/
- https://elixir-lang.org/blog/2022/09/01/elixir-v1-14-0-released/

### Decide v4 - Feature Flags

PostHog is consistently upgrading our internal data representation so that it's better for users each and every time. We've recently launched a new version of our `/decide` endpoint called `v4`. This endpoint is slightly different, which caused a small change in behavior for our flags.

`PostHog.FeatureFlag` previously included a key `value` to represent the internal structure of a flag. It was renamed to `payload` to:

1. better represent the fact that it can be both an object and a boolean
2. align it more closely with our other SDKs

### PostHog.Application

This library now depends on `Cachex`, and includes a supervision tree. There are 2 options:

1. If you have a simple application without a `YourApp.Application` application, then you can simply add `:posthog` to your `mix.exs` `application` definition

```elixir
def application do
    [
      extra_applications: [
        # ... your existing applications ...
        :posthog
      ],
    ]
  end
```

2. Or, if you're already using an Application, you can add `Posthog.Application` to your own supervision tree:

```elixir
# lib/my_app/application.ex
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Your other children...
      {PostHog.Application, []}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### `PostHog.capture` new signature

The signature to `PostHog.capture` has changed. `distinct_id` is now a required argument.

Here are some examples on how the method is now used:

```elixir
# Basic event with `event` and `distinct_id`, both required
PostHog.capture("page_view", "user_123")

# Event with properties
PostHog.capture("purchase", "user_123", %{
    product_id: "prod_123",
    price: 99.99,
    currency: "USD"
})

# Event with custom timestamp
PostHog.capture("signup_completed", "user_123", %{}, timestamp: DateTime.utc_now())

# Event with custom UUID
uuid = "..."
PostHog.capture("signup_completed", "user_123", %{}, uuid: uuid)

# Event with custom headers
PostHog.capture(
  "login",
  "user_123",
  %{},
  headers: [{"x-forwarded-for", "127.0.0.1"}]
)
```
