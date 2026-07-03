---
hex/posthog: minor
---

Emit error tracking stack frames in canonical bottom-up order: `frames[0]` is the outermost entry point and the last frame is the crash site. This aligns the Elixir SDK with the cross-SDK stack frame ordering standard.
