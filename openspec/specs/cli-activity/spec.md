# cli-activity Specification

## Purpose

Interactive progress/spinner UI for long-running command work: TTY/flag gating, multi-progress and sequential step bars, log queuing during indicators, and shared presentation rules.

## Requirements

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

### Requirement: In-place multi-line panel redraw

When activity indicators are enabled, multi-progress and sequential step-bar panels SHALL redraw in place on standard error. As the panel’s logical height grows or shrinks between frames (including when successful package rows are removed and failed rows remain), the program SHALL NOT leave prior indicator frames as permanent ghost lines above the live panel. After each redraw, the owned panel band SHALL match the current frame’s logical line count so that a subsequent redraw or full panel clear removes exactly that band and no residual indicator lines remain in the scrollback from intermediate frames of the same panel session.

#### Scenario: Shrinking multi-progress does not stack top bars

- **WHEN** the user runs `outdated` with indicators enabled and concurrent package jobs complete over time so that package rows disappear and the top-level done/total advances
- **THEN** the top-level progress bar updates in place without leaving a trail of previous `done/total` indicator lines stacked above the live panel

#### Scenario: Panel clear removes the full live band

- **WHEN** a multi-progress or step-bar panel ends (phase complete, pause for interactive UI, or teardown)
- **THEN** the program clears the entire owned panel band so that deferred logs and machine stdout are not preceded by leftover intermediate indicator frames from that panel session

#### Scenario: Growing then shrinking panel stays aligned

- **WHEN** indicators are enabled and the number of in-flight package rows increases and later decreases within one multi-progress phase
- **THEN** each redraw replaces the previous panel content in place and intermediate frames do not accumulate as permanent stderr lines

### Requirement: Step telemetry for long package pipelines

When indicators are enabled, long multi-step package pipelines (including Go tree-lane planning during `outdated` and multi-phase work during `update` phase 1) SHALL update the package row’s step total, step completion count, and current step name as work proceeds so the row reflects real progress rather than a single frozen phase label for the entire job.

For `GoVendorAndAssets` **materialize** work during `update` phase 1, when indicators are enabled the package row SHALL advance discrete steps for the chosen path rather than a single frozen `vendoring` or `publishing assets` label spanning multiple long subprocesses.

Full path (new vendor tarball build and publish) SHALL advance through these step names in order (or equivalent short phrases containing the same intent): `cloning upstream`, `go mod download`, `compressing tarball`, `committing assets`, `pushing assets`, `uploading release asset`, `regenerating manifest`. Host Go version gating MAY run under the `go mod download` step without a separate step. Hashing and sidecar writes MAY run under `committing assets`. Creating the GitHub release MAY run under `uploading release asset`.

Reuse path (existing release vendor asset) SHALL advance through: `reusing release assets`, `verifying vendor asset`, `regenerating manifest`, and SHALL NOT claim `vendoring`, `publishing assets`, `cloning upstream`, `go mod download`, `compressing tarball`, `committing assets`, `pushing assets`, or `uploading release asset` for that PV’s reuse work.

Before path selection, the package row MAY show a non-advancing status indicating release-asset probe (for example `probing release asset`) without counting as a completed materialize step. Per-package step totals SHALL account for planning steps already completed and for remaining materialize work using a full-path upper bound that is revised when a PV takes the reuse path so the step bar remains consistent.

#### Scenario: Go outdated check advances steps during planning

- **WHEN** the user runs `outdated` with indicators enabled on a `GoVendorAndAssets` package whose plan probes multiple upstream versions
- **THEN** the package row’s step progress advances through planning work (including version probes) with updating step names rather than remaining on a single static label for the whole check

#### Scenario: Full path advances through vendor and publish sub-steps

- **WHEN** indicators are enabled and apply builds and publishes a new vendor tarball for a package PV
- **THEN** the package row’s step progress advances through cloning, go mod download, compressing the tarball, committing assets, pushing assets, uploading the release asset, and regenerating the manifest (or equivalent short names with the same intent) rather than remaining on a single `vendoring` or `publishing assets` label for those phases

#### Scenario: Reuse path advances through reuse sub-steps only

- **WHEN** indicators are enabled and apply reuses an existing vendor release asset for a package PV
- **THEN** the package row’s step progress advances through reusing the release asset, verifying the vendor asset, and regenerating the manifest, and does not show full-path vendoring or publishing step names for that PV

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

### Requirement: Reuse path progress status strings

When indicators are enabled and a `GoVendorAndAssets` package PV is materialized via the **reuse** path (existing release vendor asset), the multi-progress package row SHALL use status or step names that reflect reuse and verification (phrases containing `reusing release assets` and `verifying vendor asset`, then Manifest regeneration) and SHALL NOT claim `vendoring` or `publishing assets` for that PV’s reuse work. When the same package uses the full vendor+publish path for a PV, the package row SHALL use the finer full-path step names defined under step telemetry for long package pipelines (clone, go mod download, compress, commit assets, push assets, upload release asset, regenerating manifest) rather than only coarse `vendoring` / `publishing assets` labels for the long work.

#### Scenario: Reuse statuses on progress row

- **WHEN** indicators are enabled and apply reuses an existing vendor release asset for a package PV
- **THEN** the package row’s current step or status text indicates release-asset reuse and verification rather than vendoring or publishing assets

#### Scenario: Full path shows fine-grained vendor and publish statuses

- **WHEN** indicators are enabled and apply builds and publishes a new vendor tarball for a package PV
- **THEN** the package row’s current step or status text reflects the active sub-phase among cloning, go mod download, compression, assets commit, assets push, release upload, and manifest regeneration (not a single frozen `vendoring` label for the entire build and not a single frozen `publishing assets` label for the entire publish)

### Requirement: Reliable activity panel teardown

When activity indicators are enabled, multi-progress and sequential step-bar hosts SHALL use an exception-safe mutex for all redraw, clear, pause, and resume critical sections that update the panel on standard error, so a throw during those sections cannot leave the mutex permanently acquired.

Panel lifetime SHALL be structured (parent-owned background work), not a fire-and-forget thread whose completion is signaled only by a one-shot empty MVar that the panel may never fill. After the phase body finishes (successfully or by exception), the host SHALL request cooperative stop of the panel, wait briefly for the panel to exit, and if the panel has not exited SHALL cancel the panel work and reap it so that host teardown cannot block indefinitely on progress-internal synchronization.

Panel chrome is best-effort: if the panel fails or is cancelled after the phase body has completed successfully, the program SHALL still complete the phase teardown path (including clearing the owned panel band when possible and flushing deferred logs) and SHALL NOT treat panel failure alone as a command failure for that successful body.

#### Scenario: Redraw failure does not hang the host

- **WHEN** indicators are enabled and a multi-progress or step-bar panel is active and redraw or clear throws during a locked panel update
- **THEN** the progress host still returns from the panel scope within a short bound after the phase body finishes (or after the body is abandoned), rather than blocking indefinitely on an internal MVar

#### Scenario: Phase body exception still tears down the panel

- **WHEN** indicators are enabled and the phase body under multi-progress or step-bar throws
- **THEN** the exception propagates to the caller and the panel is stopped (cooperatively or by cancel-after-grace) without leaving the process blocked indefinitely on progress-internal synchronization

#### Scenario: Successful body ignores panel failure

- **WHEN** indicators are enabled and the phase body completes successfully but the panel thread fails or is cancelled during teardown
- **THEN** the host still finishes teardown (panel band cleared when possible, deferred logs flushed) and returns the body’s success result without failing solely because of the panel

#### Scenario: Pause and resume use the same safe mutex

- **WHEN** indicators are enabled and the active panel is paused or resumed (for example for interactive GPG unlock)
- **THEN** pause/resume critical sections use the same exception-safe panel mutex as redraw so a throw during pause clear or resume cannot permanently acquire that mutex
