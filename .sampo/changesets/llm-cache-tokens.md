---
hex/posthog: patch
---

LLM analytics events captured by the Req integration now include `$ai_cache_read_input_tokens` and `$ai_cache_creation_input_tokens` for Anthropic and OpenAI-compatible Chat Completions and Responses APIs (along with `$ai_cache_reporting_exclusive: false` for inclusive OpenAI-shaped responses, when input tokens include the cache tokens), so cached input tokens are priced correctly.
