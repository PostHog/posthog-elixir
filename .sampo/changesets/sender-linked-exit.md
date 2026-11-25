---
hex/posthog: patch
---

`PostHog.Sender` no longer crashes with a `FunctionClauseError` when a linked process exits. It ignores normal exits and stops cleanly on abnormal ones, still flushing queued events.
