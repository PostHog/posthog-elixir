---
hex/posthog: minor
---

`PostHog.Emails.send/2` takes `cc`, `bcc` and `attachments` on a send with `template_key`. `cc` and `bcc` are one address or a list. Each attachment is a map with `filename`, `content` (the file's raw bytes) and optionally `content_type` and `content_id`. An email carries at most 10 files and 40 MB after Base64 encoding, about 29 MB of files. The SDK hashes each file, uploads the files PostHog doesn't have yet straight to PostHog's file storage, without the secret key, and then sends the email with references to them. If an upload fails, it sends nothing and returns `attachment_upload_failed`. An empty `reply_to`, `cc`, `bcc` or `attachments` list is now left out of the request.
