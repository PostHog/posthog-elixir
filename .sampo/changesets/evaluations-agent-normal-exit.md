---
hex/posthog: patch
---

Stop the feature flag evaluations access-tracking Agent when the process that created the snapshot exits normally, instead of leaving it running for the life of the node.
