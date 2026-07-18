## MODIFIED Requirements

### Requirement: GitMvAndManifest apply steps

For a package with technique `GitMvAndManifest` that is outdated, the apply procedure SHALL: (1) select the newest local ebuild by PV ordering; (2) verify involved paths are clean in git; (3) rename that ebuild file so its version component equals the remote PV (without inventing a revision); (4) run Portage `ebuild` on the new ebuild file with the `manifest` command from the package directory as the working directory; (5) immediately create a signed overlay git commit for that unit’s changed paths with message `category/package: version` where `version` is the remote PV string without a leading `v`. Success for that package SHALL mean the commit is present in the overlay worktree HEAD, not that paths are deferred for a later commit phase.

When the ebuild filename changes, staged paths SHALL include at least: the **old** ebuild path (so the deletion is recorded), the **new** ebuild path, and the package `Manifest`. Staging only the new ebuild and Manifest without the old path is insufficient. Other ebuild versions in the same directory that were not selected as newest SHALL be left in place and SHALL NOT be staged by this update.

#### Scenario: Rename and manifest for new PV

- **WHEN** newest local ebuild is `opencode-bin-1.17.19.ebuild` and remote PV is `1.17.20`
- **THEN** the ebuild is renamed to `opencode-bin-1.17.20.ebuild` and `ebuild ./opencode-bin-1.17.20.ebuild manifest` runs with cwd set to the package directory

#### Scenario: Commit stages old ebuild deletion with new ebuild and Manifest

- **WHEN** a successful update renames `grok-build-bin-0.2.99-r1.ebuild` to `grok-build-bin-0.2.101.ebuild` and regenerates Manifest
- **THEN** the signed commit for that package stages the old ebuild path (deletion), the new ebuild path, and `Manifest`
- **AND** after the commit the old ebuild path is not left as an unstaged deletion in the work tree solely because it was omitted from `git add`

#### Scenario: Commit message format

- **WHEN** a successful update commit is created for `dev-lang/deno-bin` at version `2.9.2`
- **THEN** the commit message is exactly `dev-lang/deno-bin: 2.9.2`

#### Scenario: Local revision does not block newer PV

- **WHEN** local newest version is `0.2.99-r1` and remote PV is `0.2.101`
- **THEN** the package is treated as outdated and the new ebuild filename uses `0.2.101` without `-r1`

#### Scenario: GitMv success is committed immediately

- **WHEN** GitMv rename and `ebuild … manifest` succeed
- **THEN** the program creates the signed overlay commit for that package before treating the package as apply success
- **AND** it does not leave those paths pending a later package-wide commit barrier

### Requirement: Dirty involved paths block package update

Before mutating an apply unit, the program SHALL check that the unit’s involved paths are clean relative to git HEAD (not modified or staged with uncommitted changes). For `GitMvAndManifest`, involved paths are the newest ebuild file and the package `Manifest`. For each `GoVendorAndAssets` planned PV unit, involved paths are the template or target ebuild path for that PV and the package `Manifest`. If any involved path is dirty, the unit SHALL hard-fail without mutating. Dirtiness of unrelated paths SHALL NOT fail the unit. After a prior unit in the same package has successfully committed, dirt from that unit SHALL NOT remain uncommitted and therefore SHALL NOT cause the next unit’s dirty check to fail solely due to that prior unit’s work.

#### Scenario: Dirty Manifest fails package

- **WHEN** the package `Manifest` has uncommitted modifications before a unit starts
- **THEN** the update unit hard-fails and the ebuild is not renamed or rewritten

#### Scenario: Unrelated dirty file does not fail package

- **WHEN** only a different package’s files are dirty
- **THEN** dirty checks for the current unit still pass

#### Scenario: Prior committed PV does not dirty-fail next PV

- **WHEN** a Go package materializes planned PV `0.82.0` successfully (including its signed overlay commit) and then materializes planned PV `0.84.0` on a tree with no foreign dirt
- **THEN** the dirty check for `0.84.0` passes even though `0.82.0` updated the shared `Manifest` earlier in the same `update` run

### Requirement: Parallel work then serial signed commits

Package check, dirty verification, vendor construction, ebuild rename/rewrite, and `ebuild … manifest` work SHALL be allowed to run concurrently across packages, except that assets-repository git commit, push, and GitHub release publish for a shared assets worktree SHALL be mutually excluded, and overlay git index mutations (`git add` and `git commit`) SHALL be mutually excluded via an overlay critical section. The program SHALL create each unit’s signed overlay commit immediately after that unit’s successful overlay mutation and verification (commit-on-unit-success). The program SHALL NOT defer all overlay commits until after every selected package has finished apply work. Global ordering of overlay commits by `category/package` is NOT required under concurrent apply; each commit SHALL include only paths belonging to that unit. Each overlay and assets commit SHALL sign with GPG (`git commit` with signing enabled); the program SHALL NOT create unsigned commits as a fallback. The program SHALL NOT read or store the GPG passphrase. Immediately before each signed overlay or assets commit, the program SHALL apply GPG sign readiness for that commit’s worktree (agent cache check; ready-prompt and unlock when cold; terminal pinentry environment) as specified by the gpg-sign-readiness capability. Signing failure, including readiness or unlock failure, SHALL be a hard failure for that unit and SHALL NOT leave an unsigned commit recorded as success.

#### Scenario: No successful units create no overlay commits

- **WHEN** every package is soft-skipped or hard-fails before a successful apply unit commit
- **THEN** the program creates no overlay git commits for those packages and does not need to prompt for GPG solely for deferred overlay commits

#### Scenario: Isolated paths per overlay commit

- **WHEN** two packages A and B both apply successfully
- **THEN** each resulting overlay commit includes only paths belonging to that package’s unit

#### Scenario: Signing failure is hard failure

- **WHEN** git commit signing fails for a unit after overlay mutation
- **THEN** that unit is recorded as a hard failure and the program does not leave an unsigned commit for it as success

#### Scenario: Assets publish serialized

- **WHEN** two packages need assets publish concurrently
- **THEN** only one package at a time performs assets commit, push, and release on the shared assets worktree

#### Scenario: Overlay commits serialized under lock

- **WHEN** two packages finish overlay mutation concurrently and both need overlay commits
- **THEN** only one overlay `git add`/`git commit` critical section runs at a time

#### Scenario: Readiness runs before assets signed commit

- **WHEN** a package publishes assets with a signed git commit and the signing keygrip cache is cold
- **THEN** the program performs GPG readiness for the assets worktree before that commit

#### Scenario: Readiness runs before overlay signed commit

- **WHEN** a unit creates a signed overlay commit and the signing keygrip cache is cold
- **THEN** the program performs GPG readiness for the overlay worktree before that commit

#### Scenario: Overlay commit not deferred to end barrier

- **WHEN** package A completes a successful GitMv unit while package B is still vendoring
- **THEN** package A’s overlay commit may already exist in HEAD before package B finishes apply work

### Requirement: Half-applied package warning

When a unit hard-fails after the ebuild was renamed or rewritten but before a successful signed overlay commit (for example `ebuild manifest` failure or signing failure after mutation), the program SHALL log an error and a warning that the package directory may be left dirty or half-applied so a later dirty check can explain retry failures.

#### Scenario: Manifest failure after rename warns dirty

- **WHEN** rename succeeds and `ebuild … manifest` fails
- **THEN** the program logs an error for the failure and a warning that the package tree may be dirty

### Requirement: GoVendorAndAssets multi-lane apply

For technique `GoVendorAndAssets`, apply SHALL run the Go tree-lane planner and, for each unique planned PV that needs materialization, perform either the **full** vendor-and-assets + overlay path or the **reuse** overlay-only path defined by `go-vendor-assets` (probe existing release asset first; reuse when present; full path when absent). The full path remains: clone tag, host Go gate, vendor tarball, assets publish, BDEPEND from that tag’s go.mod, assets SRC_URI rules. The reuse path SHALL complete overlay ebuild mutation and Manifest verification without re-publishing assets. Ebuild KEYWORDS SHALL be set to the planned `~arch` membership for that PV. After each planned PV unit successfully completes overlay mutation and verification, apply SHALL create a signed overlay commit for that PV’s paths with message `category/package: version` (version = PV without leading `v`, including `-rN` when the filename carries a revision) **before** starting the next planned PV for the same package. When two lanes share one PV and a single write satisfies both, the program SHALL produce one commit for that PV rather than two empty commits. After all planned PVs that needed materialization succeed, apply SHALL prune non-live versioned ebuilds not in the planned set per exact-set rules and SHALL create a signed overlay commit for prune pathspecs when any extras were removed. If any planned PV unit hard-fails, apply SHALL NOT prune, SHALL NOT start further planned PVs for that package after that failure, and SHALL retain any earlier successful PV commits. Sibling packages continue on hard-fail of one package’s unit.

#### Scenario: Two PVs two commits

- **WHEN** the plan needs distinct PVs `0.82.0` and `0.84.0` and both materialize successfully
- **THEN** the program creates two signed overlay commits (one per PV) before the package storm finishes
- **AND** the second PV’s dirty check does not fail solely because the first PV updated `Manifest`

#### Scenario: Shared PV one commit

- **WHEN** two lanes select the same PV and one ebuild write satisfies both
- **THEN** the program creates a single signed commit for that PV for those lanes

#### Scenario: KEYWORDS tilde only

- **WHEN** a planned ebuild is written for amd64-only membership
- **THEN** KEYWORDS contain `~amd64` and do not contain bare `amd64` without tilde

#### Scenario: Orphan after publish resumes via reuse

- **WHEN** a prior run published release `crush-0.84.0` with the vendor asset but overlay Manifest for that PV is incomplete, and the operator re-runs `update`
- **THEN** apply materializes that PV via the reuse path (no create-release) and completes overlay Manifest and signed commit when dirty checks allow

#### Scenario: Partial multi-PV success keeps earlier commits

- **WHEN** planned PV `0.82.0` commits successfully and planned PV `0.84.0` hard-fails
- **THEN** the overlay retains the signed commit for `0.82.0`
- **AND** the program does not prune unplanned ebuilds for that package in that run
- **AND** later planned PVs for that package are not started after the hard-fail

#### Scenario: Prune only after full package success

- **WHEN** all needed planned PVs for a package materialize and commit successfully and extras exist outside the planned set
- **THEN** the program removes those extras and creates a signed overlay commit including the deletions and updated Manifest
