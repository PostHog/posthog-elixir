---
hex/posthog: patch
---

When a shared `evaluate_flags` request for a flag missing from local definitions fails or reports errors, one waiting caller retries it for the others before they each make their own request.
