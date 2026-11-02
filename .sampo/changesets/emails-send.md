---
hex/posthog: minor
---

Add `PostHog.Emails` to send transactional email and read its status. `PostHog.Emails.send/2` queues one email from a template made in PostHog (`template_id` and `template_data`) or from content your code rendered (`template_key`, `subject`, and `html` and/or `text`). `PostHog.Emails.get/2` reads what happened to it. Both need a project secret API key in `secret_key`. New config options: `app_host`, `email_request_timeout_ms`, `email_request_max_retries` and `migrated_from`.
