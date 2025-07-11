# Advanced Configuration

By default, PostHog starts its own supervision tree and attaches a logger handler.
This behavior is configured by the `:posthog` option in your global configuration:

```elixir
config :posthog,
  enable: true,
  enable_error_tracking: true,
  public_url: "https://us.i.posthog.com",
  api_key: "phc_asdf"
  ...
```

However, in certain cases you might want to run this supervision tree yourself.
You can do this by disabling the default supervisor and adding `PostHog.Supervisor`
to your application tree with its own configuration:

```elixir
# config.exs

config :posthog, enable: false

config :my_app, :posthog,
  public_url: "https://us.i.posthog.com",
  api_key: "phc_asdf"

# application.ex

defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    posthog_config = Application.fetch_env!(:my_app, :posthog) |> PostHog.Config.validate!()
    
    :logger.add_handler(:posthog, PostHog.Handler, %{config: posthog_config})

    children = [
      {PostHog.Supervisor, posthog_config}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

## Multiple Instances

In even more advanced cases, you might want to interact with more than one
PostHog project. In this case, you can run multiple PostHog supervision trees,
one of which can be the default one:

```elixir
# config.exs
config :posthog,
  public_url: "https://us.i.posthog.com",
  api_key: "phc_key1"

config :my_app, :another_posthog,
  public_url: "https://us.i.posthog.com",
  api_key: "phc_key2",
  supervisor_name: AnotherPostHog
  
# application.ex
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    posthog_config = Application.fetch_env!(:my_app, :another_posthog) |> PostHog.Config.validate!()
    
    children = [
      {PostHog.Supervisor, posthog_config}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

Then, each function in the `PostHog` module accepts an optional first argument with
the name of the PostHog supervisor tree that will process the capture:

```elixir
iex> PostHog.capture(AnotherPostHog, "user_signed_up", %{distinct_id: "user123"})
```
