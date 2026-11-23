---
hex/posthog: minor
---

Schedule a transactional email with `:scheduled_at` on `PostHog.Emails.send/2`, at most 7 days ahead, on PostHog Cloud. A `NaiveDateTime`, a string without a UTC offset (`invalid_scheduled_at`), or a client whose app host isn't PostHog Cloud (`scheduling_requires_cloud`) returns an error before any request. The SDK rounds the time up to the next millisecond and checks that PostHog confirmed it, returning `schedule_not_confirmed` with the email's `:message_id` otherwise. `PostHog.Emails.SendResult` now carries `:status` (`"scheduled"` or `"queued"`) and `:scheduled_at`, `PostHog.Emails.Error` carries `:message_id`, and `PostHog.Emails.get/2` reads `"scheduled"` while a scheduled email waits.
