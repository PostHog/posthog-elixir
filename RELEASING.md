# Releasing

Releases are semi-automated using [Sampo](https://github.com/PostHog/sampo) and follow the [PostHog SDK releases process](https://posthog.com/handbook/engineering/sdks/releases).

## Creating Changesets

When making changes that should be included in the changelog, create a changeset:

```bash
# Install sampo CLI (requires Rust toolchain)
cargo install sampo

# Create a changeset describing your change
sampo add
```

Follow the prompts to specify:

- The type of change (`patch`, `minor`, or `major`)
- A description of the change for the changelog

Changesets are stored in `.sampo/changesets/` and will be consumed during the release process.

## How to trigger a release

1. **Add a changeset** to your PR describing the changes (see above)
2. **Merge the PR** into `main`. No release label is required.

Once merged, the release workflow will automatically:

- Consume all pending changesets
- Update the version in `mix.exs`
- Update `CHANGELOG.md` with the new entries
- Create a Git tag (e.g., `v2.2.0`)
- Create a GitHub Release with generated notes
- Publish the package to [Hex.pm](https://hex.pm/packages/posthog)

## Release approval

All releases require approval from the Client Libraries team via the `Release` GitHub environment. Release requests are posted to `#approvals-client-libraries` on Slack.

## Troubleshooting

### Failed or cancelled release

The independent [release failure notification workflow](.github/workflows/release-failure-notification.yml) checks every completed main-branch release attempt and alerts if a job failed, timed out, or was cancelled. This includes runner startup failures and cancellations with job records. It also alerts when the run failed without a failed job and the "Release and publish" job never ran. Once the "Release and publish" job succeeds, alerts describe follow-up problems rather than claiming the release failed, for example when the released Slack notification was skipped.

Cancelled runs with no jobs are ignored, including superseded queued runs and manual cancellations before any job is created. A rejected approval fails the "Release and publish" job, so it also posts an alert.

Job inspection retries transient GitHub API failures up to three times. If inspection still fails, it logs the HTTP status or error type and message, then posts a fallback alert with the overall run status and logs link so the release can be checked manually. Error diagnostics stay in the run log, not in the Slack message.

Alerts reply to the approval thread in the release approvals Slack channel. The release workflow preserves the thread timestamp in a run artifact for 30 days, independently of release approval. Failed-job reruns reuse the latest available thread from the same or an earlier attempt. If the timestamp is missing, invalid, or unavailable, the alert falls back to a new channel message, so it does not depend on the approval notification succeeding. The failure workflow must be present on the default branch to run; local tests do not send Slack messages.
