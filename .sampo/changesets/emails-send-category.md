---
hex/posthog: minor
---

A send with `:template_key` takes a `:category`: the key of one of the project's message categories, such as `"newsletter"`. A marketing category skips recipients who opted out, fills `{{ unsubscribe_url }}` and adds List-Unsubscribe headers.
