# Contributing

This package contains the PostHog Elixir SDK compliance adapter used with the PostHog SDK Test Harness.

## Running tests

Adapter regression tests and the harness run automatically in CI via GitHub Actions.
To run the adapter tests against a local HTTP fixture:

```bash
cd sdk_compliance_adapter
mix deps.get
PORT=18281 MOCK_PORT=19281 mix test
```

Both ports must be free. These tests exercise the SDK's real HTTP transport,
rich v2 flag evaluation, option forwarding, errors, and called-event metadata.
See [README.md](README.md#tested-profile-and-limitations) for the selected
harness inventory and known assertion mismatches.

### Locally with Docker Compose

Run the full compliance suite from the `sdk_compliance_adapter` directory:

```bash
docker-compose up --build --abort-on-container-exit
```

This will:

1. Build the Elixir SDK adapter
2. Pull the test harness image
3. Run all compliance tests
4. Show the results

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
  ghcr.io/posthog/sdk-test-harness:1.0.0 \
  run --adapter-url http://sdk-adapter:8080 --mock-url http://test-harness:8081

# Cleanup
docker stop sdk-adapter && docker rm sdk-adapter
docker network rm test-network
```
