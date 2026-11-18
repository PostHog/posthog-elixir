---
hex/posthog: patch
---

`PostHog.Emails` now sends emails, uploads attachments and reads email status through `/api/messaging/`, which takes the project from the project secret API key, instead of `/api/projects/@current/messaging/`. PostHog instances older than these routes answer 404.
