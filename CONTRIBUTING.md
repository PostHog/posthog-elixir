# Contributing

Thanks for your interest in improving the PostHog Elixir SDK.

## Developing locally

Fetch dependencies and run the test suite from the repository root:

```bash
mix deps.get
mix test
```

### Integration tests

To run the integration test suite that sends real events to the API:

1. Create a test PostHog project and obtain an API key.
2. Create `config/integration.exs` from the example file:

   ```bash
   cp config/integration.example.exs config/integration.exs
   ```

3. Put your API key into `config/integration.exs`.
4. Run the integration tests:

   ```bash
   mix test --only integration
   ```

### Local development config

If you want to play with PostHog events in IEx, create `config/dev.override.exs` and point it at the instance of your choosing. This file is gitignored. A minimal example:

```elixir
# config/dev.override.exs
import Config

config :posthog,
  enable: true,
  api_host: "https://us.i.posthog.com",
  api_key: "phc_XXXX"
```

## Pull requests

1. Fork the repository and create your feature branch.
2. Make your changes and ensure tests pass with `mix test`.
3. Run `mix format` and `mix credo --strict` to ensure code quality.
4. Open a pull request.
