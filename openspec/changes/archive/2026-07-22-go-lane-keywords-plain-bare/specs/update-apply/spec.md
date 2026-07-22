## MODIFIED Requirements

### Requirement: GoVendorAndAssets multi-lane apply

For technique `GoVendorAndAssets`, apply SHALL run the Go tree-lane planner and, for each unique planned PV that needs materialization, perform either the **full** vendor-and-assets + overlay path or the **reuse** overlay-only path defined by `go-vendor-assets` (probe existing release asset first; reuse when present; full path when absent). Before the first mutation for the package in the run, apply SHALL verify complete matching md5-cache for all non-live ebuilds in the package directory as specified by `md5-cache`. The full path remains: clone tag, host Go gate, vendor tarball, assets publish, BDEPEND from that tag’s go.mod, assets SRC_URI rules. The reuse path SHALL complete overlay ebuild mutation and Manifest verification without re-publishing assets. Ebuild KEYWORDS SHALL be set to the planned per-arch bare/`~` membership for that PV as defined by `go-tree-lanes` (including bare arch tokens when plain lanes target the PV). After each planned PV unit successfully completes overlay mutation, Manifest verification, and package-scoped egencache, apply SHALL create a signed overlay commit for that PV’s paths (including affected `metadata/md5-cache/` paths) with message `category/package: version` (version = PV without leading `v`, including `-rN` when the filename carries a revision) **before** starting the next planned PV for the same package. When two lanes share one PV and a single write satisfies both, the program SHALL produce one commit for that PV rather than two empty commits. After all planned PVs that needed materialization succeed, apply SHALL prune non-live versioned ebuilds not in the planned set per exact-set rules, regenerate Manifest and package md5-cache as needed, and SHALL create a signed overlay commit for prune pathspecs (including md5-cache) when any extras were removed. If any planned PV unit hard-fails, apply SHALL NOT prune, SHALL NOT start further planned PVs for that package after that failure, and SHALL retain any earlier successful PV commits. Sibling packages continue on hard-fail of one package’s unit.

#### Scenario: Two PVs two commits

- **WHEN** the plan needs distinct PVs `0.82.0` and `0.84.0` and both materialize successfully
- **THEN** the program creates two signed overlay commits (one per PV) before the package storm finishes
- **AND** each commit includes that unit’s md5-cache path updates
- **AND** the second PV’s dirty check does not fail solely because the first PV updated `Manifest`

#### Scenario: Shared PV one commit

- **WHEN** two lanes select the same PV and one ebuild write satisfies both
- **THEN** the program creates a single signed commit for that PV for those lanes

#### Scenario: KEYWORDS follow plain vs tilde membership

- **WHEN** a planned ebuild is written for plain amd64 membership only
- **THEN** KEYWORDS contain bare `amd64` and do not contain `~amd64`

#### Scenario: KEYWORDS tilde-only when plan has no plain membership

- **WHEN** a planned ebuild is written for tilde-only amd64 membership
- **THEN** KEYWORDS contain `~amd64` and do not contain bare `amd64`

#### Scenario: Orphan after publish resumes via reuse

- **WHEN** a prior run published release `crush-0.84.0` with the vendor asset but overlay Manifest for that PV is incomplete, and the operator re-runs `update`
- **THEN** apply materializes that PV via the reuse path (no create-release) and completes overlay Manifest, egencache, and signed commit when dirty checks and md5-cache gate allow

#### Scenario: Partial multi-PV success keeps earlier commits

- **WHEN** planned PV `0.82.0` commits successfully and planned PV `0.84.0` hard-fails
- **THEN** the overlay retains the signed commit for `0.82.0`
- **AND** the program does not prune unplanned ebuilds for that package in that run
- **AND** later planned PVs for that package are not started after the hard-fail

#### Scenario: Prune only after full package success

- **WHEN** all needed planned PVs for a package materialize and commit successfully and extras exist outside the planned set
- **THEN** the program removes those extras, regenerates Manifest and md5-cache, and creates a signed overlay commit including the deletions, updated Manifest, and md5-cache paths
