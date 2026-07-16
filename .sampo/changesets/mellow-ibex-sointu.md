---
hex/posthog: minor
---

Send minimal `$feature_flag_called` events when the `/flags` response carries the server-controlled `minimalFlagCalledEvents` gate and the evaluated flag reports `has_experiment: false`. Minimal events keep only an allowlisted set of properties (flag identity, evaluation metadata, `$groups`, `$process_person_profile`, `$lib`, `$lib_version`, `$is_server`); everything else, including context and global properties, is stripped. Experiment-linked flags and responses without the gate keep the full event shape.
