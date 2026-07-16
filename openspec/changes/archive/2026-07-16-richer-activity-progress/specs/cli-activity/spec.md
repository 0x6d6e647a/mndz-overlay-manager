## MODIFIED Requirements

### Requirement: Multi-progress for concurrent package work

For concurrent per-package work under `outdated` and `update` phase 1, when indicators are enabled the program SHALL show a multi-progress panel consisting of:

1. A top-level determinate progress bar whose done/total counter reflects **packages** that have reached a terminal state over the **total package jobs** for that phase, with a phase label
2. A row per in-flight package with a spinner, package key (`category/package`), and current step or phase name
3. When a package reports a step total greater than one, that row SHALL also show a determinate progress bar and a steps done/total counter for that package’s internal steps; when the step total is at most one or is unset, the row SHALL omit the step bar and step fraction and MAY show only the step or phase name
4. Retention of rows that end in soft-skip or hard-fail, with a non-spinner failure or warning glyph and a short reason
5. Removal of rows that complete successfully, with the top-level package done count incremented

When every package job has reached a terminal state, the program SHALL clear the entire panel before emitting deferred logs and machine stdout lines.

#### Scenario: Success removes package row

- **WHEN** a package job completes successfully during multi-progress
- **THEN** its spinner row disappears from the panel and the top-level package done count increases

#### Scenario: Failure retains package row until clear

- **WHEN** a package job soft-skips or hard-fails during multi-progress
- **THEN** its row remains on the panel in a failed or warning state until the panel is cleared at the end of the phase

#### Scenario: Panel clears before deferred output

- **WHEN** all concurrent package jobs for a phase have finished
- **THEN** the multi-progress panel is cleared and only then are queued log messages and deferred stdout lines written

#### Scenario: Multi-step package row shows step progress

- **WHEN** indicators are enabled and a package job reports a step total greater than one with a current step name
- **THEN** that package’s row includes a spinner, the package key, a determinate step progress bar, a steps done/total counter, and the current step name

#### Scenario: Single-step package row omits step bar

- **WHEN** indicators are enabled and a package job has at most one step (or no multi-step total)
- **THEN** that package’s row shows a spinner, the package key, and a phase or step name without a per-package step bar or steps done/total fraction

#### Scenario: Top bar counts packages not inner steps

- **WHEN** a multi-step package advances its inner step counter during multi-progress
- **THEN** the top-level done/total counter does not increase solely due to that inner step advance; it increases only when a package job reaches a terminal state

## ADDED Requirements

### Requirement: Step telemetry for long package pipelines

When indicators are enabled, long multi-step package pipelines (including Go tree-lane planning during `outdated` and multi-phase work during `update` phase 1) SHALL update the package row’s step total, step completion count, and current step name as work proceeds so the row reflects real progress rather than a single frozen phase label for the entire job.

#### Scenario: Go outdated check advances steps during planning

- **WHEN** the user runs `outdated` with indicators enabled on a `GoVendorAndAssets` package whose plan probes multiple upstream versions
- **THEN** the package row’s step progress advances through planning work (including version probes) with updating step names rather than remaining on a single static label for the whole check
