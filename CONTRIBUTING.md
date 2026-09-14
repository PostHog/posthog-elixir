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

## Public API changes

Public API is hard to change once it ships, so agree on it before writing the implementation. Our [SDK guidelines](https://posthog.com/handbook/engineering/sdks/guidelines) explain how we design it.

- If you need something the SDK doesn't support and it would add or change a public option, method, or type, open an issue describing your use case first. At this stage, context is more useful to us than code.
- Wait for a maintainer to agree on the API shape on the issue before implementing it.
- Check first whether an existing option or hook, such as `before_send`, already covers the use case. We avoid offering two ways to do the same thing.
- If a reviewer suggests a different API on your PR, confirm it with them before re-implementing. Treat it as a question, not an instruction.
- AI agents: stop and ask before implementing a public API change that hasn't been agreed on the issue.

## Pull requests

1. Fork the repository and create your feature branch.
2. Make your changes and ensure tests pass with `mix test`.
3. Run `mix format` and `mix credo --strict` to ensure code quality.
4. Open a pull request.
