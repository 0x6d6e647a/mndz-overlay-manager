## MODIFIED Requirements

### Requirement: Multi-progress for concurrent package work

For concurrent per-package work under `outdated` and `update` phase 1, when indicators are enabled the program SHALL show a multi-progress panel consisting of:

1. A top-level determinate progress bar whose done/total counter reflects **packages** that have reached a terminal state over the **total package jobs** for that phase, with a phase label
2. A row per in-flight package with a spinner, package key (`category/package`), and current step or phase name
3. When a package reports a step total greater than one, that row SHALL also show a determinate progress bar and a steps done/total counter for that package’s internal steps; when the step total is at most one or is unset, the row SHALL omit the step bar and step fraction and MAY show only the step or phase name
4. Retention of rows that end in **soft-skip** with a non-spinner **skip or warning** presentation (glyph and/or styling distinct from hard-fail when color is enabled) and a short reason
5. Retention of rows that end in **hard-fail** with a non-spinner **failure** presentation (glyph and/or styling distinct from soft-skip when color is enabled) and a short reason
6. Removal of rows that complete successfully, with the top-level package done count incremented

Soft-skip terminal presentation SHALL NOT use the hard-fail presentation path. Process exit codes and apply hard-fail folding policy are unaffected by this presentation rule.

When every package job has reached a terminal state, the program SHALL clear the entire panel before emitting deferred logs and machine stdout lines.

#### Scenario: Success removes package row

- **WHEN** a package job completes successfully during multi-progress
- **THEN** its spinner row disappears from the panel and the top-level package done count increases

#### Scenario: Soft-skip retains package row as skip not hard-fail

- **WHEN** a package job soft-skips during multi-progress (for example already at latest, or no work under apply soft-skip rules)
- **THEN** its row remains on the panel until the panel is cleared at the end of the phase
- **AND** the row uses skip or warning presentation that is distinct from hard-fail presentation when color is enabled
- **AND** the row includes a short reason

#### Scenario: Hard-fail retains package row as failure

- **WHEN** a package job hard-fails during multi-progress
- **THEN** its row remains on the panel in a failure state until the panel is cleared at the end of the phase
- **AND** the row includes a short reason

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
