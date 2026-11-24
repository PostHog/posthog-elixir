---
hex/posthog: minor
---

Send the same transactional email to many recipients with `PostHog.Emails.batch/2`, one email each, from a template with `:template_data` per recipient or from content in your code. A batch takes at most 100 recipients and goes out in one request. The SDK gives each recipient an idempotency key that every retry reuses, and returns a result per recipient: `"queued"`, `"failed"` or `"unconfirmed"`. A batch PostHog refuses as a whole, such as one too large (413 `too_large`), returns `{:error, %PostHog.Emails.BatchError{}}` with every recipient's result.
