---
hex/posthog: minor
---

Add a `$feature_flag_has_experiment` boolean property to `$feature_flag_called` events, sourced from the `has_experiment` field in the `/flags` response metadata. Defaults to `false` when the server does not report it.
