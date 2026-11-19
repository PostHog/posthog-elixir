---
hex/posthog: patch
---

Count Gemini URL context `toolUsePromptTokenCount` as input tokens in captured LLM generations (it was added to output tokens); Google Search retrieval is not billed as input and stays out of the totals.
