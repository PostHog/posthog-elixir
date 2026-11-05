---
hex/posthog: minor
---

The new `PostHog.Emails` sends transactional email from your Elixir code and reads each email's delivery status.

```elixir
# config/runtime.exs
config :posthog, api_key: "phc_...", secret_key: "phs_..."

{:ok, %PostHog.Emails.SendResult{id: message_id}} =
  PostHog.Emails.send(
    to: "user@example.com",
    distinct_id: "user_123",
    template_key: "password-reset",
    subject: "Reset your password",
    html: rendered_html
  )

# "delivered", "bounced", ...
{:ok, %PostHog.Emails.Status{status: status}} = PostHog.Emails.get(message_id)
```

You can also send a template made in PostHog by its `template_id`.

You need a project secret API key, the kind that starts with `phs_`. Create one under **Project secret API keys** in your project settings. Set its **Transactional email** scope to Write to send emails, or to Read for a key that only reads statuses. Set it as `secret_key` in your `:posthog` config. Set `app_host` to your PostHog app URL when you self-host PostHog or send through a reverse proxy. The SDK also loads feature flags with this key, so give it **Feature flags: Read** too, or it logs a warning each time it polls.

PostHog records each email's delivery, opens and clicks on the person with that `distinct_id`. It groups every email with the same `template_key`, so you see their metrics and logs in one place. The SDK retries a request that hits a network error, a rate limit or an outage twice by default. Every send carries an idempotency key, so a retry never sends the email twice. Pass your own `idempotency_key`, such as `welcome:user_123`, and your job runner's retries are safe too.

A send with your own content also takes `from`, `reply_to` and `capture_engagement: false`. Set `migrated_from` in your config to tell PostHog which email provider you moved from. A failed call returns `{:error, %PostHog.Emails.Error{}}` with PostHog's `code` and the HTTP `status_code`.

Docs: [Send transactional emails with Elixir](https://posthog.com/docs/workflows/transactional-emails/elixir) and the [transactional email overview](https://posthog.com/docs/workflows/transactional-emails).
