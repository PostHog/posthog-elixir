---
hex/posthog: minor
---

`PostHog.Emails.send/2` takes `cc`, `bcc` and `attachments` on a send with `template_key`. `cc` and `bcc` are one address or a list. Each attachment is a map with `filename`, `content` (the file's bytes, which the SDK encodes as Base64) and optionally `content_type` and `content_id`. An empty `reply_to`, `cc`, `bcc` or `attachments` list is now left out of the request.
