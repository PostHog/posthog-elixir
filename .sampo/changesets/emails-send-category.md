---
hex/posthog: minor
---

A send with `template_key` takes a `:category`. Without it, the email is transactional, as before, or follows the category of the template that `template_key` names. A new `%PostHog.Emails.MessageCategory{}` defines the category in code with a `key`, a `type` (`:marketing` or `:transactional`), a `name` and an optional `description`, and PostHog creates it by key on the first send. The name and description apply only then: a send never renames a category or changes its description, so change them later in PostHog. A marketing category honors the recipient's opt-outs and adds unsubscribe headers, and its HTML must link to `{{ unsubscribe_url }}`, or its text, when it has no HTML, must contain it. `PostHog.Emails.transactional_category()` sends a transactional email with no category, so PostHog refuses it with `category_mismatch` when `template_key` names a template in a category.

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
