---
hex/posthog: patch
---

Honor the definitions snapshot property_matching_version in local feature flag evaluation and shared definition caches. Missing or version 1 now intentionally matches released service legacy boolean truthiness rather than the former SDK behavior; version 2 uses explicit equality, with recursive truthiness for empty filters. Correct known-null complements and composite equality normalization.
