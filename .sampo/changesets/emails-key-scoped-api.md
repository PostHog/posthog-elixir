---
hex/posthog: patch
---

`PostHog.Emails` now sends emails, uploads attachments and reads email status through `/api/messaging/`, which takes the project from the project secret API key, instead of `/api/projects/@current/messaging/`. Needs PostHog Cloud, or a self-hosted PostHog from 2026-11-18 or later. Older self-hosted versions answer these calls with a 404.
