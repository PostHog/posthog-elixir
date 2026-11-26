---
hex/posthog: patch
---

Local evaluation of a group-aggregated flag without a usable group key now skips only the conditions on that group, as `/flags` does. A condition with its own person aggregation still runs and can match, directly or as a dependency. A flag with a holdout above 0% falls back to `/flags` in that case, because only `/flags` can decide the holdout.
