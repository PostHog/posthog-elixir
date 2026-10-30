---
hex/posthog: patch
---

Fix a process leak in feature flag snapshots. Snapshots no longer start a process to track accessed flags, so they need no cleanup and can be used from any process.

Behaviour changes:

- `PostHog.FeatureFlags.Evaluations`'s `accessed_pid` field is deprecated and always `nil`. Remove any `Agent.stop/1` call on it.
- `PostHog.FeatureFlags.Evaluations.accessed/1` no longer returns keys that were read but are missing from the snapshot.
