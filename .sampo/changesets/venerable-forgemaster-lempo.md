---
hex/posthog: patch
---

Treat failed remote feature flag records as no result, omit their values and payloads, and report evaluation_failed on direct reads.
