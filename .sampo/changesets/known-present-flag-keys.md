---
hex/posthog: patch
---

`evaluate_flags` remembers flag keys that `/flags` returned but local definitions don't have yet, until the next definitions refresh. Later evaluations request those keys directly instead of waiting on another evaluation's in-flight request.
