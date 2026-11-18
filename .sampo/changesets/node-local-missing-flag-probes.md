---
hex/posthog: patch
---

Coordinate concurrent `evaluate_flags` probes for flags missing from local definitions within each node instead of across the cluster, and cap how long overlapping evaluations wait so a slow `/flags` request no longer queues every other evaluation.
