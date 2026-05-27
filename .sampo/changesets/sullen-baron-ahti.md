---
hex/posthog: minor
---

Add new `mode` configuration option. Set it to `drop_events` to not send events to the server (useful in dev). `test_mode: true` is deprecated, use `mode: :test` instead.
