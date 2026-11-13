---
hex/posthog: minor
---

`PostHog.FeatureFlags.get_remote_config_payload/2` reads the payload of a remote config feature flag by its key, with no distinct ID. It needs the `secret_key` option. It returns `{:ok, payload}`, or `{:error, exception}` on a failure.
