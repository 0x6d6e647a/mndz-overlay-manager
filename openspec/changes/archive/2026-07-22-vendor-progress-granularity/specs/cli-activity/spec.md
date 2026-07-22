## MODIFIED Requirements

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

### Requirement: Reuse path progress status strings

When indicators are enabled and a `GoVendorAndAssets` package PV is materialized via the **reuse** path (existing release vendor asset), the multi-progress package row SHALL use status or step names that reflect reuse and verification (phrases containing `reusing release assets` and `verifying vendor asset`, then Manifest regeneration) and SHALL NOT claim `vendoring` or `publishing assets` for that PV’s reuse work. When the same package uses the full vendor+publish path for a PV, the package row SHALL use the finer full-path step names defined under step telemetry for long package pipelines (clone, go mod download, compress, commit assets, push assets, upload release asset, regenerating manifest) rather than only coarse `vendoring` / `publishing assets` labels for the long work.

#### Scenario: Reuse statuses on progress row

- **WHEN** indicators are enabled and apply reuses an existing vendor release asset for a package PV
- **THEN** the package row’s current step or status text indicates release-asset reuse and verification rather than vendoring or publishing assets

#### Scenario: Full path shows fine-grained vendor and publish statuses

- **WHEN** indicators are enabled and apply builds and publishes a new vendor tarball for a package PV
- **THEN** the package row’s current step or status text reflects the active sub-phase among cloning, go mod download, compression, assets commit, assets push, release upload, and manifest regeneration (not a single frozen `vendoring` label for the entire build and not a single frozen `publishing assets` label for the entire publish)
