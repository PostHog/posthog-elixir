---
hex/posthog: minor
---

Feature flag evaluation accepts `:person_property_keys_known_absent` and `:group_property_keys_known_absent` to list property keys the caller knows are absent. Local evaluation resolves `is_not_set`, `is_set` and the other supported operators on those keys without calling `/flags`, and remote requests send the lists so `/flags` gets the same result. A list longer than 1000 keys returns `{:error, %PostHog.Error{}}` without sending a request.
