---
hex/posthog: patch
---

A client whose secret key can't read flag definitions, such as a key without the Feature flags: Read scope, now logs one warning instead of one on every poll. The warning names the missing scope and how to turn off local evaluation. It logs again after definitions load and the key is rejected later.
