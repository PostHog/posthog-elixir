---
hex/posthog: minor
---

`PostHog.Emails.send/2` takes `track_opens_and_clicks: false` on a send with `template_key`. The email then goes out without PostHog's open pixel, so PostHog can't count its opens. PostHog doesn't track clicks on emails sent from code, so their links are never rewritten either way. It's independent of `capture_engagement`, which decides whether engagement events are captured on the recipient's person. The SDK sends the option only when you set it, and PostHog's API support for it is rolling out.
