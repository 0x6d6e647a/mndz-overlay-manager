## ADDED Requirements

### Requirement: GoVendorAndAssets multi-lane apply

For technique `GoVendorAndAssets`, apply SHALL run the Go tree-lane planner and, for each unique planned PV that needs materialization, perform the existing vendor-and-assets + overlay ebuild path targeting that PV (clone tag, host Go gate, vendor tarball, assets publish, BDEPEND from that tag’s go.mod, assets SRC_URI rules). Ebuild KEYWORDS SHALL be set to the planned `~arch` membership for that PV. After all planned PVs for the package are successfully materialized in the attempt, apply SHALL prune non-live versioned ebuilds not in the planned set per exact-set rules. Apply SHALL create signed overlay commits with message `category/package: version` (version = PV without leading `v`) **one per lane that required a distinct tree mutation**; when two lanes share one PV and a single write satisfies both, the program SHALL produce one commit for that PV rather than two empty commits. Obsolete ebuild deletions SHALL be staged with a commit of that package apply storm so they are not left unstaged. Sibling packages and other lanes continue on hard-fail of one PV subject to exact-set prune safety (do not prune replacements that never landed).

#### Scenario: Two PVs two commits

- **WHEN** the plan needs distinct PVs `0.82.0` and `0.84.0` and both materialize successfully
- **THEN** the program creates two signed commits (one per PV) unless coalescing rules reduce only identical same-PV work

#### Scenario: Shared PV one commit

- **WHEN** two lanes select the same PV and one ebuild write satisfies both
- **THEN** the program creates a single signed commit for that PV for those lanes

#### Scenario: KEYWORDS tilde only

- **WHEN** a planned ebuild is written for amd64-only membership
- **THEN** KEYWORDS contain `~amd64` and do not contain bare `amd64` without tilde

### Requirement: GitMvAndManifest leaves other versions

`GitMvAndManifest` apply behavior for non-selected ebuild versions in the package directory SHALL remain as today (other versions left in place). Exact-set pruning applies only to `GoVendorAndAssets` tree-lane apply.

#### Scenario: Binary update does not delete siblings

- **WHEN** a `GitMvAndManifest` package directory has two ebuild versions and newest is renamed to a new remote PV
- **THEN** the non-selected older ebuild is left in place by that technique

## MODIFIED Requirements

### Requirement: GoVendorAndAssets is a first-class apply technique

Packages with technique `GoVendorAndAssets` SHALL be applied via the Go vendor and assets publish path and the Go tree-lane multi-PV planner, not soft-skipped as unsupported. Target version selection SHALL use tree-lane plan PVs rather than solely the single latest remote version.

#### Scenario: Outdated Go package uses vendor path

- **WHEN** a `GoVendorAndAssets` package has a tree-lane gap and is selected for update
- **THEN** apply uses the Go vendor/assets path for each needed planned PV rather than soft-skipping as unsupported
