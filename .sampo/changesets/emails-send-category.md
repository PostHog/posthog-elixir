---
hex/posthog: minor
---

`PostHog.Emails.send/2` takes a `:category`. Left out, or `PostHog.Emails.transactional_category()`, the email is transactional, as before. The key of one of the project's marketing message categories sends a marketing email in that category: PostHog honors the recipient's opt-outs and adds unsubscribe headers, and the content must contain `{{ unsubscribe_url }}`.

```elixir
PostHog.Emails.send(
  to: "user@example.com",
  template_key: "product-update",
  subject: "What's new",
  html: rendered_html_with_unsubscribe_url,
  category: "product-updates",
  distinct_id: "user_123"
)
```
