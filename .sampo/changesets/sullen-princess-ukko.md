---
hex/posthog: minor
---

This is *technically* a breaking change because we're now always sending data gzip compressed and people might not want that, but this will not break anyone's code so we'll release it as a minor knowing that it's an improvement. It's always been possible to swap the client off, but we weren't documenting how to do that exactly - this is now solved too.
