---
hex/posthog: patch
---

Normalize event timestamp overrides from before_send to UTC without losing fractional precision, and send explicit defaults in feature flag requests.
