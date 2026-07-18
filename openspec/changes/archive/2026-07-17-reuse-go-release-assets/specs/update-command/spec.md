## MODIFIED Requirements

### Requirement: Go tree-lane update selection

For packages with technique `GoVendorAndAssets`, `update` SHALL use the Go tree-lane planner to determine target PVs and whether the package needs work. With zero package arguments, `update` SHALL include a Go package when any lane has a gap (missing target PV ebuild, content or Manifest fix needed, or exact-set prune required), not only when newest local is less than upstream latest. Explicit targets that are fully satisfied under the plan (including Manifest vendor DIST completeness) SHALL be soft-skipped.

#### Scenario: Zero-arg update includes multi-lane gap

- **WHEN** the user runs `update` with no arguments and a Go package’s newest local equals upstream latest but a second planned PV for another Go ceiling is missing
- **THEN** the program still attempts that package’s lane apply work

#### Scenario: Satisfied Go package soft-skipped

- **WHEN** the user runs `update crush` and crush’s package dir already matches the planned unique PV set with correct content and Manifest vendor entries
- **THEN** the package is soft-skipped without hard-fail

#### Scenario: Incomplete Manifest not soft-skipped

- **WHEN** the user runs `update crush` and planned PVs have ebuilds but Manifest lacks a vendor DIST for a planned PV
- **THEN** the package is not soft-skipped solely as already matching the plan

### Requirement: Go tree-lane update stdout

For each successfully applied Go tree lane (or coalesced same-PV apply that satisfies one or more lanes), the program SHALL write stdout lines of the form `category/package vFROM -> vTO (dev-lang/go …)` using lane labels from `go-tree-lanes`. Split mapping: one local → multiple news yields one line per target with the same `vFROM`. Converge mapping: multiple locals → one new yields one line per local `vFROM` to that `vTO`. Soft-skipped or hard-failed lanes SHALL NOT produce success lines.

When a success line corresponds to a PV that was materialized via the **reuse** path (existing release asset; no vendor rebuild/publish for that PV), the program SHALL append the token ` [assets reused]` to that line. Lines for PVs materialized via the full vendor+publish path SHALL NOT include that token.

#### Scenario: Split success lines

- **WHEN** a Go package had local `0.80.0` only and successfully materializes targets `0.82.0` and `0.84.0` for two lanes via the full path
- **THEN** stdout includes `… v0.80.0 -> v0.82.0 (…)` and `… v0.80.0 -> v0.84.0 (…)` with the correct lane labels and without requiring ` [assets reused]`

#### Scenario: Converge success lines

- **WHEN** locals `0.80.0` and `0.82.0` successfully converge to `0.84.0`
- **THEN** stdout includes `… v0.80.0 -> v0.84.0` and `… v0.82.0 -> v0.84.0` with appropriate labels

#### Scenario: Reuse success marked

- **WHEN** a planned PV is successfully completed via the reuse path
- **THEN** each success stdout line for that PV includes the substring ` [assets reused]`
