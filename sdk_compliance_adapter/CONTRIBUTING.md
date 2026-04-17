# Contributing

This package contains the PostHog Elixir SDK compliance adapter used with the PostHog SDK Test Harness.

## Running tests

Tests run automatically in CI via GitHub Actions.

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
  ghcr.io/posthog/sdk-test-harness:latest \
  run --adapter-url http://sdk-adapter:8080 --mock-url http://test-harness:8081

# Cleanup
docker stop sdk-adapter && docker rm sdk-adapter
docker network rm test-network
```
