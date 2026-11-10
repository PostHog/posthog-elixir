---
hex/posthog: minor
---

`PostHog.Emails.send/2` takes `:tracking` on a send with `template_key` to choose what PostHog tracks for the email. Left out, PostHog counts opens and captures engagement events, and doesn't track clicks. `true` turns on opens, clicks and engagement events, and `false` turns them all off. A map such as `%{clicks: true}` sets `:opens`, `:clicks` and `:engagement` one by one. `:capture_engagement` is deprecated in favor of `tracking: %{engagement: false}`; it still works, but a send can't set both. The SDK sends `:tracking` only when you set it, and PostHog's API support for it is rolling out.
