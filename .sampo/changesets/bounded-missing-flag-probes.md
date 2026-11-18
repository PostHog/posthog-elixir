---
hex/posthog: patch
---

Evaluating a flag that has no local definition no longer takes a cluster-wide lock. Concurrent evaluations of the same missing key coordinate only on the same node. They wait at most one second for the probe in flight, then make their own `/flags` request. Waiters no longer make their requests one at a time after a probe that returns the key or fails.
