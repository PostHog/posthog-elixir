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
2. **Add the `release` label** to the PR when it's ready for release
3. **Merge the PR** into `main`

Once merged, the release workflow will automatically:

- Consume all pending changesets
- Update the version in `mix.exs`
- Update `CHANGELOG.md` with the new entries
- Create a Git tag (e.g., `v2.2.0`)
- Create a GitHub Release with generated notes
- Publish the package to [Hex.pm](https://hex.pm/packages/posthog)

## Release approval

All releases require approval from the Client Libraries team via the `Release` GitHub environment. Release requests are posted to `#approvals-client-libraries` on Slack.
