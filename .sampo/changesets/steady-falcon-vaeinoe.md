---
hex/posthog: minor
---

Add a `$feature_flag_has_experiment` boolean property to `$feature_flag_called` events, sourced from the `has_experiment` field in the `/flags` response metadata. The property is only sent when the server explicitly reports the field; it is omitted when unknown (older deployments).
