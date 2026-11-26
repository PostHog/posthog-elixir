---
hex/posthog: patch
---

Local evaluation now treats a group key that is not a non-empty string or a number, such as `""`, a boolean, a list or a map, as no group key, as `/flags` does. A flag aggregated on that group type resolves `false` without calling `/flags`, a group condition on it in a person flag is skipped, and such a key no longer buckets the flag or raises when a snapshot is built.
