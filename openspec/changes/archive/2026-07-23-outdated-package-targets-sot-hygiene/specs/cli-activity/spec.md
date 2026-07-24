## RENAMED Requirements

- FROM: `### Requirement: layoutz-backed presentation`
- TO: `### Requirement: In-process multi-line progress presentation`

## MODIFIED Requirements

### Requirement: In-process multi-line progress presentation

Activity indicators SHALL be rendered in-process as multi-line terminal progress presentation (progress bars, spinners, and inline multi-row updates) on standard error when enabled. The program SHALL NOT require a particular third-party library name in product requirements; log severity formatting remains independent of the progress renderer.

#### Scenario: Progress uses multi-line stderr presentation

- **WHEN** indicators are enabled for package work
- **THEN** the progress presentation is multi-line terminal chrome on stderr (bars, spinners, or equivalent inline layout) and is not written to stdout

### Requirement: Reuse path progress status strings

When indicators are enabled and a `DepsAndAssets` Go package PV is materialized via the **reuse** path (existing release vendor asset), the multi-progress package row SHALL use status or step names that reflect reuse and verification (phrases containing `reusing release assets` and `verifying vendor asset`, then Manifest regeneration) and SHALL NOT claim `vendoring` or `publishing assets` for that PV’s reuse work. When the same package uses the full vendor+publish path for a PV, the package row SHALL use the finer full-path step names defined under step telemetry for long package pipelines (clone, go mod download, compress, commit assets, push assets, upload release asset, regenerating manifest) rather than only coarse `vendoring` / `publishing assets` labels for the long work.

#### Scenario: Reuse statuses on progress row

- **WHEN** indicators are enabled and apply reuses an existing vendor release asset for a package PV
- **THEN** the package row’s current step or status text indicates release-asset reuse and verification rather than vendoring or publishing assets

#### Scenario: Full path shows fine-grained vendor and publish statuses

- **WHEN** indicators are enabled and apply builds and publishes a new vendor tarball for a package PV
- **THEN** the package row’s current step or status text reflects the active sub-phase among cloning, go mod download, compression, assets commit, assets push, release upload, and manifest regeneration (not a single frozen `vendoring` label for the entire build and not a single frozen `publishing assets` label for the entire publish)

### Requirement: Reliable activity panel teardown

When activity indicators are enabled, multi-progress and sequential step-bar hosts SHALL use an exception-safe mutual exclusion mechanism for all redraw, clear, pause, and resume critical sections that update the panel on standard error, so a throw during those sections cannot leave the panel lock permanently acquired.

Panel lifetime SHALL be structured (parent-owned background work), not fire-and-forget work whose completion is signaled only by a one-shot empty completion signal that the panel may never fill. After the phase body finishes (successfully or by exception), the host SHALL request cooperative stop of the panel, wait briefly for the panel to exit, and if the panel has not exited SHALL cancel the panel work and reap it so that host teardown cannot block indefinitely on progress-internal synchronization.

Panel chrome is best-effort: if the panel fails or is cancelled after the phase body has completed successfully, the program SHALL still complete the phase teardown path (including clearing the owned panel band when possible and flushing deferred logs) and SHALL NOT treat panel failure alone as a command failure for that successful body.

#### Scenario: Redraw failure does not hang the host

- **WHEN** indicators are enabled and a multi-progress or step-bar panel is active and redraw or clear throws during a locked panel update
- **THEN** the progress host still returns from the panel scope within a short bound after the phase body finishes (or after the body is abandoned), rather than blocking indefinitely on progress-internal synchronization

#### Scenario: Phase body exception still tears down the panel

- **WHEN** indicators are enabled and the phase body under multi-progress or step-bar throws
- **THEN** the exception propagates to the caller and the panel is stopped (cooperatively or by cancel-after-grace) without leaving the process blocked indefinitely on progress-internal synchronization

#### Scenario: Successful body ignores panel failure

- **WHEN** indicators are enabled and the phase body completes successfully but the panel worker fails or is cancelled during teardown
- **THEN** the host still finishes teardown (panel band cleared when possible, deferred logs flushed) and returns the body’s success result without failing solely because of the panel

#### Scenario: Pause and resume use the same safe mutex

- **WHEN** indicators are enabled and the active panel is paused or resumed (for example for interactive GPG unlock)
- **THEN** pause/resume critical sections use the same exception-safe panel lock as redraw so a throw during pause clear or resume cannot permanently acquire that lock
