---
hex/posthog: patch
---

Local evaluation now resolves a group-aggregated flag when its group is not passed, as `/flags` does, instead of falling back to `/flags`. Conditions on that group don't match, so a flag with only those conditions returns `false`. This also applies to a flag that another flag depends on.
