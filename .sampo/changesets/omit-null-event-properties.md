---
hex/posthog: patch
---

Omit null object properties recursively when serializing events while preserving array positions, encoder-produced values, and intentional feature flag and exception metadata.
