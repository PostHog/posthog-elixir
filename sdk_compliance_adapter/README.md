# PostHog Elixir SDK Compliance Adapter

This adapter wraps the posthog-elixir SDK for compliance testing with the [PostHog SDK Test Harness](https://github.com/PostHog/posthog-sdk-test-harness).

## Running Tests

Tests run automatically in CI via GitHub Actions. See the test harness repo for details.

### Locally with Docker Compose

```bash
# From the posthog-elixir/sdk_compliance_adapter directory
docker-compose up --build --abort-on-container-exit
```

This will:

1. Build the Elixir SDK adapter
2. Pull the test harness image
3. Run all compliance tests
4. Show results

### Manually with Docker

```bash
# Create network
docker network create test-network

# Build and run adapter
docker build -f sdk_compliance_adapter/Dockerfile -t posthog-elixir-adapter .
docker run -d --name sdk-adapter --network test-network -p 8080:8080 posthog-elixir-adapter

# Run test harness
docker run --rm \
  --name test-harness \
  --network test-network \
  ghcr.io/posthog/sdk-test-harness:latest \
  run --adapter-url http://sdk-adapter:8080 --mock-url http://test-harness:8081

# Cleanup
docker stop sdk-adapter && docker rm sdk-adapter
docker network rm test-network
```

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

- `GET /health` - Health check, returns SDK name/version
- `POST /init` - Initialize SDK with configuration
- `POST /capture` - Capture a single event
- `POST /flush` - Flush pending events
- `GET /state` - Get internal state for test assertions
- `POST /reset` - Reset SDK state

## Documentation

For complete documentation, see:

- [PostHog SDK Test Harness](https://github.com/PostHog/posthog-sdk-test-harness)
- [Adapter Implementation Guide](https://github.com/PostHog/posthog-sdk-test-harness/blob/main/ADAPTER_GUIDE.md)
