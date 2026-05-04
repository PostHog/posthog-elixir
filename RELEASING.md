# Releasing

This repository uses [Sampo](https://github.com/bruits/sampo) for versioning and changelog generation, with GitHub Actions handling publishing.

## How to Release

1. When making a change that should be released, include a Sampo changeset:

   ```bash
   sampo add
   ```

2. Commit the generated `.sampo/changesets/*.md` file with your pull request.
3. After review, merge the PR to `main`. No GitHub release label is required.
4. A push to `main` that includes `.sampo/changesets/*.md` changes automatically starts the release workflow.
5. Approve the release when prompted in Slack / the GitHub `Release` environment.

After approval, The workflow runs Sampo, publishes the Hex package, tags the release, and creates a GitHub Release.

## Manual Trigger

You can also manually trigger the release workflow from the Actions tab with `workflow_dispatch`. Manual runs still require pending Sampo changesets.

## Troubleshooting

If the release workflow reports that no changesets were found, make sure your PR includes at least one releasable `.sampo/changesets/*.md` file.
