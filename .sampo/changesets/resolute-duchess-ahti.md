---
hex/posthog: minor
---

Add `PostHog.FeatureFlags.get_remote_config_payload/2`. It fetches the payload of a remote config feature flag from PostHog's authenticated remote config endpoint and needs `secret_key`. It returns `{:ok, payload}` with the decoded JSON value, `{:ok, nil}` when the flag has no payload or the instance is disabled, and `{:error, exception}` when `secret_key` is missing, the flag key is empty, `.`, or `..`, PostHog answers with a status other than 2xx or a body that is not JSON, or the request fails. The function makes one request per call, caches nothing, and sends no `$feature_flag_called` event.
