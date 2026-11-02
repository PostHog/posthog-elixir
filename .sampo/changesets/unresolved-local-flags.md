---
hex/posthog: minor
---

Report flags that local evaluation could not resolve on `PostHog.FeatureFlags.evaluate_flags/2` snapshots. The new `unresolved_flags` field of `PostHog.FeatureFlags.Evaluations` maps each such flag key to a reason: `:experience_continuity`, `:unsupported_definition`, `:unresolved_dependency` or `:missing_context`. When flag definitions load, log one warning for each flag that local evaluation can never resolve (experience continuity, a static cohort, an unknown operator, a malformed value, a regex that only the server can evaluate, or a missing or circular flag dependency), and log it again only when the definition of that flag changes.

Behaviour changes (these apply to every flag function, including `check/3` and `get_feature_flag_result/4`, not only to `evaluate_flags/2`):

- A condition no longer stops at a filter that only the server can evaluate, such as a static cohort. If another filter in the condition does not match, the condition does not match, and a later condition can resolve the flag locally. Before, such a flag fell back to a remote request, or stayed unresolved with `only_evaluate_locally: true`.
- An unexpected error in a filter that follows a filter local evaluation can't check now makes only that condition inconclusive, and a later condition can still resolve the flag. Before, the flag fell back to a remote request, or stayed unresolved with `only_evaluate_locally: true`.
- A condition that depends on a flag that only the server can evaluate, such as a flag with a static cohort, now makes the flag fall back to a remote request, or stay unresolved with `only_evaluate_locally: true`. Before, a later condition could resolve the flag locally to a different value than the server returns. A condition that depends on a flag with experience continuity enabled is still only inconclusive: a later condition can still resolve the flag, and only when none does, the flag falls back to a remote request, or stays unresolved with `only_evaluate_locally: true`.
- `$feature_flag_called` events from snapshot reads report `local_evaluation_inconclusive` instead of `flag_missing` for flags in `unresolved_flags`.
