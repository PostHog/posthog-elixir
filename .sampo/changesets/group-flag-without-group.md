---
hex/posthog: patch
---

Local evaluation now returns `false` for a group-aggregated flag when its group is not passed, as `/flags` does, instead of falling back to `/flags`. This also applies to a flag that another flag depends on.
