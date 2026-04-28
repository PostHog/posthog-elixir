# PostHog Elixir SDK Compliance Adapter

This adapter wraps the posthog-elixir SDK for compliance testing with the [PostHog SDK Test Harness](https://github.com/PostHog/posthog-sdk-test-harness).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for local build and compliance test instructions.

## Implementation

See [lib/sdk_compliance_adapter/](lib/sdk_compliance_adapter/) for the adapter implementation.

The adapter implements the standard SDK adapter interface defined in the [test harness CONTRACT](https://github.com/PostHog/posthog-sdk-test-harness/blob/main/CONTRACT.yaml).

### Architecture

The adapter is a standalone Elixir application that:

1. Starts an HTTP server (using Plug/Cowboy) on port 8080
2. Dynamically starts/stops the PostHog SDK based on `/init` and `/reset` requests
3. Uses a custom `TrackedClient` to intercept HTTP requests and track them for assertions
4. Maintains state (events captured, sent, retries, etc.) for the test harness to query

### Endpoints

- `GET /health` - Health check, returns SDK name/version and supported capabilities
- `POST /init` - Initialize SDK with configuration
- `POST /capture` - Capture a single event
- `POST /flush` - Flush pending events
- `POST /get_feature_flag` - Evaluate a feature flag against the `/flags` API
- `GET /state` - Get internal state for test assertions
- `POST /reset` - Reset SDK state

### Capabilities

The adapter declares `capture_v0` and `encoding_gzip` capabilities, which gates
the test suites the harness will run. The `feature_flags` suite has no
capability requirement and runs unconditionally.

## Documentation

For complete documentation, see:

- [PostHog SDK Test Harness](https://github.com/PostHog/posthog-sdk-test-harness)
- [Adapter Implementation Guide](https://github.com/PostHog/posthog-sdk-test-harness/blob/main/ADAPTER_GUIDE.md)
