---
hex/posthog: minor
---

A send with `template_key` takes a `:category`. Without it, the email is transactional, as before. A new `%PostHog.Emails.MessageCategory{}` defines the category in code with a `key`, a `type` (`:marketing` or `:transactional`), a `name` and an optional `description`, and PostHog creates it by key on the first send. A marketing category honors the recipient's opt-outs and adds unsubscribe headers, and the content must contain `{{ unsubscribe_url }}`. `PostHog.Emails.transactional_category()` sends a transactional email with no category.

```elixir
PostHog.Emails.send(
  to: "user@example.com",
  template_key: "newsletter-2026-11",
  subject: "What's new",
  html: rendered_html_with_unsubscribe_url,
  category: %PostHog.Emails.MessageCategory{
    key: "newsletter",
    type: :marketing,
    name: "Newsletter"
  },
  distinct_id: "user_123"
)
```
