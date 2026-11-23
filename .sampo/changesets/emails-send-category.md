---
hex/posthog: minor
---

A send with `template_key` takes a `:category`. Content from your code is transactional with no category unless its `:category` says otherwise; when code-send categories are enabled for the project, a `:template_key` that names a template in a category files it under that (transactional) category. When code-send categories aren't enabled for the project yet, omitting `:category` sends as transactional with no category, passing a `%PostHog.Emails.MessageCategory{}` returns HTTP 400 `categories_not_enabled`, and an older PostHog server rejects `:category` with HTTP 400. A new `%PostHog.Emails.MessageCategory{}` defines the category in code with a `key`, a `type` (`:marketing` or `:transactional`), a `name` and an optional `description`; for unmatched template keys, PostHog creates it by key on the first send (or restores a deleted one). The name and description apply only then: a send never renames a category or changes its description, so change them later in PostHog. A matching saved template keeps its own category, including when it has none: passing a `%PostHog.Emails.MessageCategory{}` for an uncategorized saved template returns `category_mismatch` (omit `:category` or pass `PostHog.Emails.transactional_category()` instead). A marketing category honors the recipient's opt-outs and adds unsubscribe headers. PostHog refuses a marketing email from code with `unsubscribe_link_required` unless its `:html` includes a clickable `<a href="{{ unsubscribe_url }}">` link (or its `:text`, when it has no `:html`, contains `{{ unsubscribe_url }}`), with `copies_not_allowed` when it has cc or bcc recipients, and with `workflow_can_wait` when it carries attachments (because marketing sending limits can hold delivery). Templates made in PostHog send transactional email only: PostHog checks transactional status first (`template_not_transactional`), and refuses a template that was made transactional and is in a marketing category with `marketing_template`. `PostHog.Emails.transactional_category()` sends a transactional email with no category, so PostHog refuses it with `category_mismatch` when `template_key` names a template in a category.

```elixir
PostHog.Emails.send(
  to: "user@example.com",
  template_key: "newsletter-2026-11",
  subject: "What's new",
  html: ~s(<p>What's new.</p><p><a href="{{ unsubscribe_url }}">Unsubscribe</a></p>),
  category: %PostHog.Emails.MessageCategory{
    key: "newsletter",
    type: :marketing,
    name: "Newsletter"
  },
  distinct_id: "user_123"
)
```
