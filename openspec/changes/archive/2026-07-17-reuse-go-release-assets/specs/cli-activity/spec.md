## ADDED Requirements

### Requirement: Reuse path progress status strings

When indicators are enabled and a `GoVendorAndAssets` package PV is materialized via the **reuse** path (existing release vendor asset), the multi-progress package row SHALL use status or step names that reflect reuse and verification (for example phrases containing `reusing release assets` and `verifying vendor asset`, then Manifest regeneration) and SHALL NOT claim `vendoring` or `publishing assets` for that PV’s reuse work. When the same package uses the full vendor+publish path for a PV, existing vendoring/publishing status strings remain appropriate for that PV.

#### Scenario: Reuse statuses on progress row

- **WHEN** indicators are enabled and apply reuses an existing vendor release asset for a package PV
- **THEN** the package row’s current step or status text indicates release-asset reuse and verification rather than vendoring or publishing assets

#### Scenario: Full path still shows vendoring

- **WHEN** indicators are enabled and apply builds and publishes a new vendor tarball for a package PV
- **THEN** the package row may show vendoring and publishing assets statuses for that work
