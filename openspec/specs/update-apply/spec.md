# update-apply Specification

## Purpose

Package policy (hardcoded source + technique), applying updates (`GitMvAndManifest` and `GoVendorAndAssets`), dirty checks, assets publish coordination, and creating isolated GPG-signed commits in the overlay work tree.

## Requirements

### Requirement: Package policy model

The library SHALL model a package policy that binds a package key `category/package` to an update source and an update technique. The technique SHALL be one of: `GitMvAndManifest`; `GoVendorAndAssets` with an optional go.mod subdirectory; or `Unsupported` with a human-readable reason. Policy lookup SHALL use a hardcoded map only.

#### Scenario: Supported GitMv technique entry

- **WHEN** policy is looked up for a package configured as `GitMvAndManifest` with a GitHub source
- **THEN** apply logic receives both the source (for version fetch) and the `GitMvAndManifest` technique

#### Scenario: Supported GoVendor technique entry

- **WHEN** policy is looked up for a package configured as `GoVendorAndAssets` with a go.mod subdirectory option
- **THEN** apply logic receives both the source and the `GoVendorAndAssets` technique including the subdirectory option

#### Scenario: Unsupported technique entry

- **WHEN** policy is looked up for a package configured as `Unsupported` with reason text
- **THEN** apply logic can soft-skip without attempting rename or manifest regeneration

### Requirement: Hardcoded policy covers known overlay packages

The hardcoded policy map SHALL include an entry for every package known to ship in the mndz overlay at the time of this change, each with both a source and a technique. At minimum, `dev-lang/bun-bin`, `dev-lang/deno-bin`, `dev-util/grok-build-bin`, and `dev-util/opencode-bin` SHALL use `GitMvAndManifest`. At minimum, `dev-db/dolt`, `dev-util/beads`, and `dev-util/crush` SHALL use `GoVendorAndAssets`. Packages that still require npm deps tarballs or cargo CRATES regeneration SHALL use `Unsupported`.

#### Scenario: Simple binary package is GitMvAndManifest

- **WHEN** policy is resolved for `dev-util/opencode-bin`
- **THEN** the technique is `GitMvAndManifest`

#### Scenario: Go package is GoVendorAndAssets

- **WHEN** policy is resolved for `dev-util/beads`
- **THEN** the technique is `GoVendorAndAssets`

#### Scenario: Cargo package is Unsupported

- **WHEN** policy is resolved for `dev-util/mise`
- **THEN** the technique is `Unsupported`

### Requirement: GitMvAndManifest apply steps

For a package with technique `GitMvAndManifest` that is outdated, the apply procedure SHALL: (1) select the newest local ebuild by PV ordering; (2) verify involved paths are clean in git; (3) rename that ebuild file so its version component equals the remote PV (without inventing a revision); (4) run Portage `ebuild` on the new ebuild file with the `manifest` command from the package directory as the working directory; (5) after a successful phase barrier for commits, stage that package’s changed paths and create a signed git commit with message `category/package: version` where `version` is the remote PV string without a leading `v`.

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

### Requirement: Dirty involved paths block package update

Before mutating a package, `GitMvAndManifest` SHALL check that the newest ebuild file and the package `Manifest` are clean relative to git HEAD (not modified or staged with uncommitted changes). If either path is dirty, the package SHALL hard-fail without renaming. Dirtiness of unrelated paths SHALL NOT fail the package.

#### Scenario: Dirty Manifest fails package

- **WHEN** the package `Manifest` has uncommitted modifications
- **THEN** the update for that package hard-fails and the ebuild is not renamed

#### Scenario: Unrelated dirty file does not fail package

- **WHEN** only a different package’s files are dirty
- **THEN** dirty checks for the current package still pass

### Requirement: Parallel work then serial signed commits

Package check, dirty verification, vendor construction, ebuild rename/rewrite, and `ebuild … manifest` work SHALL be allowed to run concurrently across packages, except that assets-repository git commit, push, and GitHub release publish for a shared assets worktree SHALL be mutually excluded. Overlay git index mutations (`git add` and `git commit`) SHALL be serialized with mutual exclusion. The program SHALL finish all successful package apply work before starting the overlay commit phase (barrier). The overlay commit phase SHALL run only when at least one package succeeded in apply. Overlay commits SHALL be ordered by `category/package` sort order. Each overlay and assets commit SHALL sign with GPG (`git commit` with signing enabled); the program SHALL NOT create unsigned commits as a fallback. The program SHALL NOT read or store the GPG passphrase. Immediately before each signed overlay or assets commit, the program SHALL apply GPG sign readiness for that commit’s worktree (agent cache check; ready-prompt and unlock when cold; terminal pinentry environment) as specified by the gpg-sign-readiness capability. Signing failure, including readiness or unlock failure, SHALL be a hard failure for that package attempt and SHALL NOT leave an unsigned commit recorded as success.

#### Scenario: No successes skips commit phase

- **WHEN** every package is soft-skipped or hard-fails before a successful apply
- **THEN** the program creates no overlay git commits and does not need to prompt for GPG for overlay commits

#### Scenario: Isolated paths per overlay commit

- **WHEN** two packages A and B both apply successfully
- **THEN** each resulting overlay commit includes only paths belonging to that package

#### Scenario: Signing failure is hard failure

- **WHEN** git commit signing fails for a package
- **THEN** that package is recorded as a hard failure and the program does not leave an unsigned commit for it as success

#### Scenario: Assets publish serialized

- **WHEN** two packages need assets publish concurrently
- **THEN** only one package at a time performs assets commit, push, and release on the shared assets worktree

#### Scenario: Readiness runs before assets signed commit

- **WHEN** a package publishes assets with a signed git commit and the signing keygrip cache is cold
- **THEN** the program performs GPG readiness for the assets worktree before that commit

#### Scenario: Readiness runs before overlay signed commit

- **WHEN** the overlay commit phase runs a signed commit for a successful package and the signing keygrip cache is cold
- **THEN** the program performs GPG readiness for the overlay worktree before that commit

### Requirement: Half-applied package warning

When a package hard-fails after the ebuild was renamed but before a successful commit (for example `ebuild manifest` failure), the program SHALL log an error and a warning that the package directory may be left dirty or half-applied so a later dirty check can explain retry failures.

#### Scenario: Manifest failure after rename warns dirty

- **WHEN** rename succeeds and `ebuild … manifest` fails
- **THEN** the program logs an error for the failure and a warning that the package tree may be dirty

### Requirement: Overlay is a git worktree for update

The `update` apply path SHALL require the overlay path to be inside a git work tree. If it is not, the program SHALL hard-fail on the spine or at the start of apply with an error (no partial updates).

#### Scenario: Non-git overlay fails

- **WHEN** the configured overlay path is not a git work tree
- **THEN** the program logs an error and does not apply package updates

### Requirement: GoVendorAndAssets is a first-class apply technique

Packages with technique `GoVendorAndAssets` SHALL be applied via the Go vendor and assets publish path and the Go tree-lane multi-PV planner, not soft-skipped as unsupported. Target version selection SHALL use tree-lane plan PVs rather than solely the single latest remote version. Behavior of the vendor/assets pipeline is defined by the `go-vendor-assets` and `assets-publish` capabilities; lane planning by `go-tree-lanes`.

#### Scenario: Outdated Go package is not soft-skipped as unsupported

- **WHEN** `dev-util/crush` is outdated and policy technique is `GoVendorAndAssets`
- **THEN** the program attempts the Go vendor assets apply path rather than soft-skipping with an unsupported reason

#### Scenario: Outdated Go package uses vendor path

- **WHEN** a `GoVendorAndAssets` package has a tree-lane gap and is selected for update
- **THEN** apply uses the Go vendor/assets path for each needed planned PV rather than soft-skipping as unsupported

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

### Requirement: Reuse path does not take assets publish critical section

When a planned PV is materialized via the reuse path (existing release asset), the program SHALL NOT hold the assets-repo git critical section solely for that PV’s materialization. Full-path publish for other packages or other PVs SHALL continue to serialize assets git/push/release as specified by `assets-publish`.

#### Scenario: Reuse while another package publishes

- **WHEN** package A reuses an existing release asset and package B needs a full assets publish
- **THEN** package A’s reuse work does not block on the assets git lock for commit/push/release of A’s PV

### Requirement: GitMvAndManifest leaves other versions

`GitMvAndManifest` apply behavior for non-selected ebuild versions in the package directory SHALL remain as today (other versions left in place). Exact-set pruning applies only to `GoVendorAndAssets` tree-lane apply.

#### Scenario: Binary update does not delete siblings

- **WHEN** a `GitMvAndManifest` package directory has two ebuild versions and newest is renamed to a new remote PV
- **THEN** the non-selected older ebuild is left in place by that technique

### Requirement: Assets publish failure does not cancel sibling packages

A hard failure during assets commit, push, or release for one package SHALL NOT abort in-progress or pending apply attempts for other packages. Only that package’s overlay mutation SHALL be skipped.

#### Scenario: One assets failure others continue

- **WHEN** package A fails assets push and package B is still applying
- **THEN** package B may still complete successfully and the program continues until all selected packages are processed
