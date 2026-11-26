---
hex/posthog: patch
---

Local feature flag evaluation no longer matches filters of an unsupported type, such as `person_metadata`, against caller-supplied properties with the same key. Those filters are now inconclusive with the `:unsupported_definition` reason, and the flag falls back to remote evaluation unless another filter or condition decides it.
