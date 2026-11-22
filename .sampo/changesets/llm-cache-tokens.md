---
hex/posthog: patch
---

LLM analytics events captured by the Req integration now include `$ai_cache_read_input_tokens` and `$ai_cache_creation_input_tokens` for Anthropic, and `$ai_cache_read_input_tokens` for OpenAI Chat Completions and Responses, so cached input tokens are priced correctly.
