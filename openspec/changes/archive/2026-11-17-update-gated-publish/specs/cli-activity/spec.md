# Spec Delta

## MODIFIED Requirements

### Requirement: Step telemetry for long package pipelines

When indicators are enabled, long multi-step package pipelines (including Go tree-lane planning during `outdated` and multi-phase work during `update` phase 1) SHALL update the package row’s step total, step completion count, and current step name as work proceeds so the row reflects real progress rather than a single frozen phase label for the entire job.

For `DepsAndAssets` Go **materialize** work during `update` phase 1, when indicators are enabled the package row SHALL advance discrete steps for the chosen path rather than a single frozen `vendoring` or `publishing assets` label spanning multiple long subprocesses.

Full path (new vendor tarball build and publish) SHALL advance through these step names in order (or equivalent short phrases containing the same intent): `cloning upstream`, `go mod download`, `compressing tarball`, `regenerating manifest`, `smoke testing`, `committing assets`, `pushing assets`, `uploading release asset`, `verifying published asset`. Host Go version gating MAY run under the `go mod download` step without a separate step. Hashing and sidecar writes MAY run under `committing assets`. Creating the GitHub release MAY run under `uploading release asset`.

Reuse path (existing release vendor asset) SHALL advance through: `reusing release assets`, `verifying vendor asset`, `regenerating manifest`, `smoke testing`, and SHALL NOT claim `vendoring`, `publishing assets`, `cloning upstream`, `go mod download`, `compressing tarball`, `committing assets`, `pushing assets`, `uploading release asset`, or `verifying published asset` for that PV’s reuse work.

`GitMvAndManifest` work SHALL show a `smoke testing` step after its Manifest and md5-cache regeneration.

Before path selection, the package row MAY show a non-advancing status indicating release-asset probe (for example `probing release asset`) without counting as a completed materialize step. Per-package step totals SHALL account for planning steps already completed and for remaining materialize work using a full-path upper bound that is revised when a PV takes the reuse path so the step bar remains consistent.

#### Scenario: Go outdated check advances steps during planning

- **WHEN** the user runs `outdated` with indicators enabled on a `DepsAndAssets` Go package whose plan probes multiple upstream versions
- **THEN** the package row’s step progress advances through planning work (including version probes) with updating step names rather than remaining on a single static label for the whole check

#### Scenario: Full path advances through vendor and publish sub-steps

- **WHEN** indicators are enabled and apply builds and publishes a new vendor tarball for a package PV
- **THEN** the package row’s step progress advances through cloning, go mod download, compressing the tarball, regenerating the manifest, smoke testing, committing assets, pushing assets, uploading the release asset, and verifying the published asset (or equivalent short names with the same intent) rather than remaining on a single `vendoring` or `publishing assets` label for those phases

#### Scenario: Reuse path advances through reuse sub-steps only

- **WHEN** indicators are enabled and apply reuses an existing vendor release asset for a package PV
- **THEN** the package row’s step progress advances through reusing the release asset, verifying the vendor asset, regenerating the manifest, and smoke testing, and does not show full-path vendoring or publishing step names for that PV

## ADDED Requirements

### Requirement: Gate waits are visible

When indicators are enabled, a unit waiting for the smoke lane SHALL show a status naming that wait. A unit waiting at its gate for an overlay dependency SHALL show a status naming the dependency. During a gated run the row SHALL name the lane label of the run in progress when the run has one.

#### Scenario: Waiting on a dependency

- **WHEN** `codex-acp` waits at its gate for `dev-util/codex`
- **THEN** its package row shows a status naming `dev-util/codex`

#### Scenario: Lane run in progress

- **WHEN** the tilde-lane gated run of `dev-util/beads-1.3.5` is active
- **THEN** the beads row's status includes `dev-lang/go ~amd64`

### Requirement: Overlay push is visible in the commit progress

When indicators are enabled, the sequential commit progress bar SHALL show the overlay push of each unit as part of that unit's commit step, naming the package while the push is in progress.

#### Scenario: Push in progress

- **WHEN** the overlay push for `dev-util/hk` is in progress
- **THEN** the commit progress bar names `dev-util/hk`
