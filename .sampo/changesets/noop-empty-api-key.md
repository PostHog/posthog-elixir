---
hex/posthog: patch
---

Start in disabled/no-op mode instead of raising or sending events when the API key is missing, blank, or the supervisor is unavailable.
