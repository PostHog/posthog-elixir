---
hex/posthog: patch
---

Send a `posthog-elixir/<version>` User-Agent header on all API requests so PostHog recognizes the SDK as server-side and includes flags gated to the server runtime in `/flags` responses.
