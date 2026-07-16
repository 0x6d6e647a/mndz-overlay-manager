## ADDED Requirements

### Requirement: Activity indicators on stderr only

When activity indicators are enabled, the program SHALL render progress bars, spinners, and related chrome exclusively on standard error. Standard output SHALL NOT receive indicator frames or cursor-control sequences.

#### Scenario: Indicator output is on stderr

- **WHEN** the user runs `outdated` or `update` on a TTY with progress enabled
- **THEN** animated indicator content is written to stderr and not to stdout

### Requirement: Indicator enablement gate

Activity indicators SHALL be enabled only when standard error is a terminal and the global `--no-progress` flag is not set. When indicators are disabled, the program SHALL perform the same functional work without rendering a progress panel.

#### Scenario: Non-TTY disables indicators

- **WHEN** stderr is not a terminal (for example when piped)
- **THEN** the program does not render progress bars or spinners

#### Scenario: --no-progress disables indicators

- **WHEN** the user passes `--no-progress`
- **THEN** the program does not render progress bars or spinners even if stderr is a terminal

### Requirement: Multi-progress for concurrent package work

For concurrent per-package work under `outdated` and `update` phase 1, when indicators are enabled the program SHALL show a multi-progress panel consisting of:

1. A top-level determinate progress bar with a done/total counter and a phase label
2. A row per in-flight package with a spinner, package key, and optional short phase description
3. Retention of rows that end in soft-skip or hard-fail, with a non-spinner failure or warning glyph and a short reason
4. Removal of rows that complete successfully, with the top-level done count incremented

When every package job has reached a terminal state, the program SHALL clear the entire panel before emitting deferred logs and machine stdout lines.

#### Scenario: Success removes package row

- **WHEN** a package job completes successfully during multi-progress
- **THEN** its spinner row disappears from the panel and the top-level done count increases

#### Scenario: Failure retains package row until clear

- **WHEN** a package job soft-skips or hard-fails during multi-progress
- **THEN** its row remains on the panel in a failed or warning state until the panel is cleared at the end of the phase

#### Scenario: Panel clears before deferred output

- **WHEN** all concurrent package jobs for a phase have finished
- **THEN** the multi-progress panel is cleared and only then are queued log messages and deferred stdout lines written

### Requirement: Sequential step bars for preflight and commits

When indicators are enabled, `update` preflight SHALL show a sequential determinate progress bar with done/total and a description of the current preflight step, clearing when preflight completes. When indicators are enabled, the sequential signed-commit phase SHALL show a sequential determinate progress bar with done/total and the current package being committed, clearing when commits complete. These phases SHALL NOT use multi-row package spinners.

#### Scenario: Preflight bar clears

- **WHEN** update preflight runs with indicators enabled and completes successfully
- **THEN** a step progress bar is shown during preflight and is cleared afterward

#### Scenario: Commit bar only

- **WHEN** update is committing multiple successful packages with indicators enabled
- **THEN** a single sequential progress bar is shown (not a multi-spinner panel) and is cleared after commits finish

### Requirement: Deferred logs during active indicators

While an activity indicator panel is active, the program SHALL NOT write persistent co-log messages to stderr immediately. Such messages SHALL be queued and emitted in order after the panel is cleared. Compact failure or warning text on the indicator row itself is allowed during the panel.

#### Scenario: Warning appears after clear

- **WHEN** a package is unconfigured during an indicated `outdated` run
- **THEN** the full warning log line is written to stderr only after the multi-progress panel is cleared

### Requirement: layoutz-backed presentation

Activity indicators SHALL be implemented using the `layoutz` library for rendering progress bars, spinners, and multi-line inline updates. Log severity formatting SHALL NOT be required to use `layoutz`.

#### Scenario: Progress uses layoutz

- **WHEN** indicators are enabled for package work
- **THEN** the progress presentation is produced via layoutz primitives or apps (for example spinners, bars, or inline layout apps)
