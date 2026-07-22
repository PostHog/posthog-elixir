---
hex/posthog: patch
---

Group captured log messages by logging call site instead of message content. Plain log messages often interpolate dynamic values (ids, URLs, inspected terms), and using the message as the exception type created a separate error tracking issue for every distinct message. The exception type is now `Logger <level> (<Module.function/arity>)` when call-site metadata is available; the full message remains in the exception value.
