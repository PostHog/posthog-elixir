---
hex/posthog: minor
---

Add `PostHog.FeatureFlags.evaluate_flags/2` and the `PostHog.FeatureFlags.Evaluations` snapshot so a single `/flags` call can power both flag branching and event enrichment for one request:

```elixir
{:ok, snapshot} = PostHog.FeatureFlags.evaluate_flags("user-123")

if PostHog.FeatureFlags.Evaluations.enabled?(snapshot, "new-dashboard") do
  render_new_dashboard()
end

PostHog.FeatureFlags.set_in_context(snapshot)
PostHog.capture("page_viewed", %{distinct_id: "user-123"})
```

The snapshot exposes `enabled?/2`, `get_flag/2`, `get_flag_payload/2`, `only/2`, `keys/1`, and `event_properties/1`. Pass `flag_keys: [...]` to `evaluate_flags/2` to scope the underlying `/flags` request itself.

`$feature_flag_called` events fired from `check/3`, `check!/3`, `get_feature_flag_result/4`, and the new snapshot path now attach `$feature_flag_id`, `$feature_flag_version`, `$feature_flag_reason`, `$feature_flag_request_id`, and `$feature_flag_error` (combining `errors_while_computing_flags` and, on the snapshot path, `flag_missing`) when the response provides them. `%PostHog.FeatureFlags.Result{}` gains matching `:id`, `:version`, `:reason`, `:request_id`, `:evaluated_at`, and `:errors_while_computing` fields.

Existing `check/3`, `check!/3`, and `get_feature_flag_result/4` continue to work unchanged.
