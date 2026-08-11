## ADDED Requirements

### Requirement: Update plan phase multi-progress

When activity indicators are enabled, the `update` plan phase SHALL show a multi-progress panel for concurrent per-package planning (same presentation family as `outdated` package checks), with package rows for the selected set (or the packages being planned). Valid check-cache hits SHALL skip upstream plan or latest network sub-steps for that package but SHALL still complete the row (including local adequacy work) rather than omitting the package from the panel solely because of a cache hit. The plan panel SHALL clear when the plan phase finishes or fails hard at spine level. The plan phase SHALL NOT use only a sequential single-step bar as the sole presentation for per-package planning when indicators are enabled and more than zero packages are planned.

#### Scenario: Plan panel for bare update

- **WHEN** the user runs bare `update` with indicators enabled and multiple packages are selected for planning
- **THEN** a multi-progress planning panel is shown before the disk-space gate and mutate multi-progress

#### Scenario: Cache hit still shows package row

- **WHEN** indicators are enabled and a package has a valid check-cache plan hit during `update` plan
- **THEN** that package still appears in the plan multi-progress and completes without repeating the cached network plan work
