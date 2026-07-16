## ADDED Requirements

### Requirement: Concurrent outdated checks

The `outdated` per-package check loop SHALL run package checks concurrently, subject to the global jobs limit. Functional outcomes (stdout outdated lines, soft warnings, exit status) SHALL remain equivalent to sequential checking aside from wall-clock timing and indicator presentation.

#### Scenario: Multiple packages checked under concurrency

- **WHEN** the user runs `outdated` against an overlay with multiple discovered packages
- **THEN** the program may check packages concurrently and still emits correct outdated stdout lines and soft warnings for each package

### Requirement: Outdated multi-progress when enabled

When activity indicators are enabled, `outdated` SHALL present multi-progress for the check phase (top-level done/total bar and per-package spinner rows as specified by `cli-activity`). Go or other technique sub-phases do not apply to checks; rows MAY show a short status such as fetching when useful.

#### Scenario: TTY outdated shows multi-progress

- **WHEN** the user runs `outdated` with indicators enabled
- **THEN** a multi-progress panel is shown during package checks and is cleared before deferred report output

### Requirement: Deferred outdated report emission

When activity indicators were shown for the check phase, the program SHALL emit `outdated` stdout lines and soft-warning log lines only after the check multi-progress panel is cleared. When indicators are disabled, emission timing MAY remain immediate after each report is known or after the batch completes, but stdout format and warning semantics SHALL be unchanged.

#### Scenario: Stdout lines appear after panel clear

- **WHEN** indicators are enabled and at least one package is outdated
- **THEN** the `category/package vLOCAL -> vREMOTE` lines are written to stdout only after the check progress panel has been cleared
