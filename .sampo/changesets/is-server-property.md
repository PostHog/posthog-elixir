---
hex/posthog: patch
---

Add a configurable `$is_server` event property (default `true`) so PostHog can identify server-side events. Set `is_server: false` when using posthog-elixir as a client/CLI so the device OS is attributed normally.
