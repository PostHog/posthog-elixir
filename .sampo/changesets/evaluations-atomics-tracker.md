---
hex/posthog: patch
---

Fix a memory leak in feature flag snapshots. Every `PostHog.FeatureFlags.evaluate_flags/2` call (and every `Evaluations.only/2` or `Evaluations.only_accessed/1` call) started a process to track accessed flags, and that process lived until the calling process exited. Long-lived callers such as GenServers, LiveViews, channels, and queue consumers built up one process per evaluation. The OpenFeature provider also sent an `{:EXIT, pid, :normal}` message on every evaluation to callers that trap exits, which filled their mailboxes.

Snapshots now track access with `:atomics`, which are freed together with the snapshot. No process is started, no cleanup is needed, and a snapshot can be used from any process.

Behaviour changes:

- The `accessed_pid` field of `PostHog.FeatureFlags.Evaluations` was removed and replaced by an opaque `accessed` field. Code that read `accessed_pid`, for example to call `Agent.stop/1` on it, must drop that code. No cleanup is needed anymore.
- `PostHog.FeatureFlags.Evaluations.accessed/1` now only returns accessed keys that are present in the snapshot. Keys that were read but missing from the snapshot are no longer included. `only_accessed/1` already ignored these keys, so its result is unchanged, and reading a missing key still sends `$feature_flag_called` with the `flag_missing` error.
