## MODIFIED Requirements

### Requirement: GoVendorAndAssets multi-lane apply

For technique `GoVendorAndAssets`, apply SHALL run the Go tree-lane planner and, for each unique planned PV that needs materialization, perform either the **full** vendor-and-assets + overlay path or the **reuse** overlay-only path defined by `go-vendor-assets` (probe existing release asset first; reuse when present; full path when absent). The full path remains: clone tag, host Go gate, vendor tarball, assets publish, BDEPEND from that tag’s go.mod, assets SRC_URI rules. The reuse path SHALL complete overlay ebuild mutation and Manifest verification without re-publishing assets. Ebuild KEYWORDS SHALL be set to the planned `~arch` membership for that PV. After all planned PVs for the package are successfully materialized in the attempt, apply SHALL prune non-live versioned ebuilds not in the planned set per exact-set rules. Apply SHALL create signed overlay commits with message `category/package: version` (version = PV without leading `v`) **one per lane that required a distinct tree mutation**; when two lanes share one PV and a single write satisfies both, the program SHALL produce one commit for that PV rather than two empty commits. Obsolete ebuild deletions SHALL be staged with a commit of that package apply storm so they are not left unstaged. Sibling packages and other lanes continue on hard-fail of one PV subject to exact-set prune safety (do not prune replacements that never landed).

#### Scenario: Two PVs two commits

- **WHEN** the plan needs distinct PVs `0.82.0` and `0.84.0` and both materialize successfully
- **THEN** the program creates two signed commits (one per PV) unless coalescing rules reduce only identical same-PV work

#### Scenario: Shared PV one commit

- **WHEN** two lanes select the same PV and one ebuild write satisfies both
- **THEN** the program creates a single signed commit for that PV for those lanes

#### Scenario: KEYWORDS tilde only

- **WHEN** a planned ebuild is written for amd64-only membership
- **THEN** KEYWORDS contain `~amd64` and do not contain bare `amd64` without tilde

#### Scenario: Orphan after publish resumes via reuse

- **WHEN** a prior run published release `crush-0.84.0` with the vendor asset but overlay Manifest for that PV is incomplete, and the operator re-runs `update`
- **THEN** apply materializes that PV via the reuse path (no create-release) and completes overlay Manifest when dirty checks allow

## ADDED Requirements

### Requirement: Reuse path does not take assets publish critical section

When a planned PV is materialized via the reuse path (existing release asset), the program SHALL NOT hold the assets-repo git critical section solely for that PV’s materialization. Full-path publish for other packages or other PVs SHALL continue to serialize assets git/push/release as specified by `assets-publish`.

#### Scenario: Reuse while another package publishes

- **WHEN** package A reuses an existing release asset and package B needs a full assets publish
- **THEN** package A’s reuse work does not block on the assets git lock for commit/push/release of A’s PV
