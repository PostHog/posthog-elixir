---
hex/posthog: minor
---

Improve Error Tracking for complex errors. If an error has a `crash_reason`, which is common for OTP reports, the SDK will report it as a chain of two exceptions. Additionally, some valuable information, such as process label, genserver state or last message, will be extracted from the report and put into event properties.
