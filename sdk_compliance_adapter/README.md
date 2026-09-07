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
- `POST /flush` - Wait for the configured sender timer (not a blocking SDK flush)
- `POST /get_feature_flag` - Call `PostHog.FeatureFlags.evaluate_flags/2` and `Evaluations.get_flag/2`
- `GET /state` - Get internal state for test assertions
- `POST /reset` - Reset SDK state

### Capabilities

The adapter declares `capture_v0` and `encoding_gzip` capabilities, which gates
the test suites the harness will run. The `feature_flags` suite has no
capability requirement and runs unconditionally.

### Tested profile and limitations

The adapter uses the SDK source in this repository, `PostHog.bare_capture/4`,
and the default Req transport with gzip. Capture uses the existing single-sender
configuration with a default batch threshold of 1 and timer of 100ms. This is
not the production multi-sender batching configuration.

Flag actions scope evaluation with `flag_keys: [key]` and forward only supplied
`person_properties`, `groups`, `group_properties`, and `disable_geoip` options.
No local definitions are configured, so each evaluation uses the remote SDK
path for either value of `force_remote`. The SDK owns request construction,
response parsing, retries, and `$feature_flag_called` events.

Harness 1.0.0 selects 30 server V0 capture tests and 17 feature-flag tests.
The following assertions remain selected and are expected to fail:

- `capture.format_validation.non_utc_event_timestamp_is_converted_to_utc`:
  standard capture has no timestamp override. The public `before_send` hook
  runs after timestamp serialization and does not normalize an injected value.
- `feature_flags.request_payload.groups_default_to_empty_object` and
  `feature_flags.request_payload.disable_geoip_omitted_defaults_to_false`:
  the SDK omits unspecified options rather than serializing these defaults.
- `feature_flags.request_lifecycle.mock_response_value_is_returned_to_caller`,
  `feature_flags.retry_behavior.retries_flags_on_502`,
  `feature_flags.retry_behavior.retries_flags_on_504`, and
  `feature_flags.side_effect_events.get_feature_flag_captures_feature_flag_called_event`:
  these fixtures return legacy-only `featureFlags`; the public evaluator
  requires rich v2 `flags`. Request and retry traffic still comes from the SDK.
  Adapter regression tests cover rich v2 values, retries, and SDK event metadata.

The existing `/flush` endpoint waits for the timer plus 500ms; the SDK has no
public flush API, so this is not a guarantee of delivery or retry completion.
State counters are approximate: retry attempts, dropped events, and SDK-generated
flag events are not fully accounted for. Capture does not return an event UUID;
wire UUID generation remains SDK-owned. Init does not map `max_retries` or
`enable_compression`; this profile uses SDK transport defaults. V1 capture,
dedicated AI capture, and non-gzip codecs are not advertised. Compliance remains
advisory; a green workflow is not proof that every selected assertion passed.

## Documentation

For complete documentation, see:

- [PostHog SDK Test Harness](https://github.com/PostHog/posthog-sdk-test-harness)
- [Adapter Implementation Guide](https://github.com/PostHog/posthog-sdk-test-harness/blob/main/ADAPTER_GUIDE.md)
