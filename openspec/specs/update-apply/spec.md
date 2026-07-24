# update-apply Specification

## Purpose

Package policy (hardcoded source + technique), applying updates (`GitMvAndManifest` and `DepsAndAssets`), dirty checks, assets publish coordination, and creating isolated GPG-signed commits in the overlay work tree.

## Requirements

### Requirement: Package policy model

The library SHALL model a package policy that binds a package key `category/package` to an update source and an update technique. The technique SHALL be one of: `GitMvAndManifest`; `DepsAndAssets` with an ecosystem specification (`Go` with optional go.mod subdirectory, `Npm`, `Bun`, or `Cargo` with optional lock/package subdirectories); or `Unsupported` with a human-readable reason. Policy lookup SHALL use a hardcoded map only. There SHALL NOT be a separate legacy Go-only technique alternative outside `DepsAndAssets`.

#### Scenario: Supported GitMv technique entry

- **WHEN** policy is looked up for a package configured as `GitMvAndManifest` with a GitHub source
- **THEN** apply logic receives both the source (for version fetch) and the `GitMvAndManifest` technique

#### Scenario: Supported DepsAndAssets Go technique entry

- **WHEN** policy is looked up for a package configured as `DepsAndAssets` with ecosystem `Go` and a go.mod subdirectory option
- **THEN** apply logic receives both the source and the `DepsAndAssets` technique including the Go subdirectory option

#### Scenario: Supported DepsAndAssets Npm technique entry

- **WHEN** policy is looked up for a package configured as `DepsAndAssets Npm`
- **THEN** apply logic receives the `DepsAndAssets` technique with ecosystem `Npm`

#### Scenario: Supported DepsAndAssets Cargo technique entry

- **WHEN** policy is looked up for a package configured as `DepsAndAssets Cargo`
- **THEN** apply logic receives the `DepsAndAssets` technique with ecosystem `Cargo`

#### Scenario: Unsupported technique entry

- **WHEN** policy is looked up for a package configured as `Unsupported` with reason text
- **THEN** apply logic can soft-skip without attempting rename or manifest regeneration

### Requirement: Hardcoded policy covers known overlay packages

The hardcoded policy map SHALL include an entry for every package known to ship in the mndz overlay that this manager automates, each with both a source and a technique. At minimum, `dev-lang/bun-bin`, `dev-lang/deno-bin`, `dev-util/grok-build-bin`, and `dev-util/opencode-bin` SHALL use `GitMvAndManifest`. At minimum, `dev-db/dolt`, `dev-util/beads`, and `dev-util/crush` SHALL use `DepsAndAssets` with ecosystem `Go`. At minimum, `dev-util/openspec` SHALL use `DepsAndAssets Npm` and `dev-util/ralph-tui` SHALL use `DepsAndAssets Bun`. At minimum, `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` SHALL use `DepsAndAssets` with ecosystem `Cargo`. No package known solely for cargo CRATES list regeneration SHALL remain `Unsupported` for that reason alone.

#### Scenario: Simple binary package is GitMvAndManifest

- **WHEN** policy is resolved for `dev-util/opencode-bin`
- **THEN** the technique is `GitMvAndManifest`

#### Scenario: Go package is DepsAndAssets Go

- **WHEN** policy is resolved for `dev-util/beads`
- **THEN** the technique is `DepsAndAssets` with ecosystem `Go`

#### Scenario: openspec is DepsAndAssets Npm

- **WHEN** policy is resolved for `dev-util/openspec`
- **THEN** the technique is `DepsAndAssets Npm`

#### Scenario: mise is DepsAndAssets Cargo

- **WHEN** policy is resolved for `dev-util/mise`
- **THEN** the technique is `DepsAndAssets Cargo`

### Requirement: GitMvAndManifest apply steps

For a package with technique `GitMvAndManifest` that is outdated, the apply procedure SHALL: (1) select the newest local ebuild by PV ordering; (2) verify the package’s non-live ebuilds have complete matching md5-cache as specified by the `md5-cache` capability (hard-fail with `gencache` / `gencache --force` recovery text when not); (3) verify involved paths are clean in git; (4) rename that ebuild file so its version component equals the remote PV (without inventing a revision); (5) run Portage `ebuild` on the new ebuild file with the `manifest` command from the package directory as the working directory; (6) run package-scoped Portage `egencache` for `category/package` as specified by `md5-cache`; (7) immediately create a signed overlay git commit for that unit’s changed paths with message `category/package: version` where `version` is the remote PV string without a leading `v`. Success for that package SHALL mean the commit is present in the overlay worktree HEAD, not that paths are deferred for a later commit phase.

When the ebuild filename changes, staged paths SHALL include at least: the **old** ebuild path (so the deletion is recorded), the **new** ebuild path, the package `Manifest`, and the affected `metadata/md5-cache/` paths for that package. Staging only the new ebuild and Manifest without the old path or without cache paths after a successful egencache is insufficient. Other ebuild versions in the same directory that were not selected as newest SHALL be left in place and SHALL NOT be staged by this update except as required for shared Manifest/cache package regeneration side effects already covered by package-scoped egencache path inclusion.

#### Scenario: Rename and manifest for new PV

- **WHEN** newest local ebuild is `opencode-bin-1.17.19.ebuild` and remote PV is `1.17.20`
- **THEN** the ebuild is renamed to `opencode-bin-1.17.20.ebuild` and `ebuild ./opencode-bin-1.17.20.ebuild manifest` runs with cwd set to the package directory

#### Scenario: Commit stages old ebuild deletion with new ebuild Manifest and cache

- **WHEN** a successful update renames `grok-build-bin-0.2.99-r1.ebuild` to `grok-build-bin-0.2.101.ebuild`, regenerates Manifest, and regenerates md5-cache
- **THEN** the signed commit for that package stages the old ebuild path (deletion), the new ebuild path, `Manifest`, and affected md5-cache paths
- **AND** after the commit the old ebuild path is not left as an unstaged deletion in the work tree solely because it was omitted from `git add`

#### Scenario: Commit message format

- **WHEN** a successful update commit is created for `dev-lang/deno-bin` at version `2.9.2`
- **THEN** the commit message is exactly `dev-lang/deno-bin: 2.9.2`

#### Scenario: Local revision does not block newer PV

- **WHEN** local newest version is `0.2.99-r1` and remote PV is `0.2.101`
- **THEN** the package is treated as outdated and the new ebuild filename uses `0.2.101` without `-r1`

#### Scenario: GitMv success is committed immediately

- **WHEN** GitMv rename, `ebuild … manifest`, and package egencache succeed
- **THEN** the program creates the signed overlay commit for that package before treating the package as apply success
- **AND** it does not leave those paths pending a later package-wide commit barrier

#### Scenario: Missing cache blocks GitMv before rename

- **WHEN** the package would be updated but md5-cache is missing for a non-live ebuild
- **THEN** the unit hard-fails without renaming the ebuild

### Requirement: Dirty involved paths block package update

Before mutating an apply unit, the program SHALL check that the unit’s involved paths are clean relative to git HEAD (not modified or staged with uncommitted changes). For `GitMvAndManifest`, involved paths are the newest ebuild file and the package `Manifest`. For each `DepsAndAssets` planned PV unit, involved paths are the template or target ebuild path for that PV and the package `Manifest`. If any involved path is dirty, the unit SHALL hard-fail without mutating. Dirtiness of unrelated paths SHALL NOT fail the unit. After a prior unit in the same package has successfully committed, dirt from that unit SHALL NOT remain uncommitted and therefore SHALL NOT cause the next unit’s dirty check to fail solely due to that prior unit’s work.

#### Scenario: Dirty Manifest fails package

- **WHEN** the package `Manifest` has uncommitted modifications before a unit starts
- **THEN** the update unit hard-fails and the ebuild is not renamed or rewritten

#### Scenario: Unrelated dirty file does not fail package

- **WHEN** only a different package’s files are dirty
- **THEN** dirty checks for the current unit still pass

#### Scenario: Prior committed PV does not dirty-fail next PV

- **WHEN** a DepsAndAssets package materializes planned PV `0.82.0` successfully (including its signed overlay commit) and then materializes planned PV `0.84.0` on a tree with no foreign dirt
- **THEN** the dirty check for `0.84.0` passes even though `0.82.0` updated the shared `Manifest` earlier in the same `update` run

### Requirement: Parallel work then serial signed commits

Package check, md5-cache consistency gate, dirty verification, vendor construction, ebuild rename/rewrite, and `ebuild … manifest` work SHALL be allowed to run concurrently across packages, except that assets-repository git commit, push, and GitHub release publish for a shared assets worktree SHALL be mutually excluded, and package-scoped `egencache` together with overlay git index mutations (`git add` and `git commit`) SHALL be mutually excluded via an overlay critical section. The program SHALL create each unit’s signed overlay commit immediately after that unit’s successful overlay mutation, manifest, egencache, and verification (commit-on-unit-success). The program SHALL NOT defer all overlay commits until after every selected package has finished apply work. Global ordering of overlay commits by `category/package` is NOT required under concurrent apply; each commit SHALL include only paths belonging to that unit (including that unit’s md5-cache paths). Each overlay and assets commit SHALL sign with GPG (`git commit` with signing enabled); the program SHALL NOT create unsigned commits as a fallback. The program SHALL NOT read or store the GPG passphrase. Immediately before each signed overlay or assets commit, the program SHALL apply GPG sign readiness for that commit’s worktree (agent cache check; ready-prompt and unlock when cold; terminal pinentry environment) as specified by the gpg-sign-readiness capability. Signing failure, including readiness or unlock failure, SHALL be a hard failure for that unit and SHALL NOT leave an unsigned commit recorded as success.

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
- **THEN** only one overlay `egencache`/`git add`/`git commit` critical section runs at a time

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

When a unit hard-fails after the ebuild was renamed or rewritten but before a successful signed overlay commit (for example `ebuild manifest` failure, `egencache` failure, or signing failure after mutation), the program SHALL log an error and a warning that the package directory may be left dirty or half-applied so a later dirty check or md5-cache consistency gate can explain retry failures, and SHALL mention that cache reconciliation may require `gencache` or `gencache --force` when ebuild and cache disagree.

#### Scenario: Manifest failure after rename warns dirty

- **WHEN** rename succeeds and `ebuild … manifest` fails
- **THEN** the program logs an error for the failure and a warning that the package tree may be dirty

#### Scenario: egencache failure after manifest warns cache repair

- **WHEN** rename and manifest succeed and package egencache fails
- **THEN** the program logs an error and a warning that mentions possible need for `gencache` / `gencache --force` before retry

### Requirement: Overlay is a git worktree for update

The `update` apply path SHALL require the overlay path to be inside a git work tree. If it is not, the program SHALL hard-fail on the spine or at the start of apply with an error (no partial updates).

#### Scenario: Non-git overlay fails

- **WHEN** the configured overlay path is not a git work tree
- **THEN** the program logs an error and does not apply package updates

### Requirement: DepsAndAssets is a first-class apply technique

`DepsAndAssets` SHALL be a first-class apply technique for Go, Npm, Bun, and Cargo ecosystems. Apply SHALL plan via runtime lanes, materialize or reuse distfiles, publish assets on the full path, rewrite overlay ebuilds, verify Manifest digests, and commit per successful PV unit as specified by `deps-assets`, `runtime-lanes`, `go-vendor-assets`, `npm-deps-assets`, `bun-deps-assets`, and `cargo-crates-assets`. Soft-skip solely for “unsupported vendor/deps/crates assets” SHALL NOT apply to packages configured with `DepsAndAssets`.

#### Scenario: DepsAndAssets package is not soft-skipped as unsupported

- **WHEN** apply runs for a package with technique `DepsAndAssets` that needs work
- **THEN** the program does not soft-skip solely because vendor, deps, or crates assets are required

### Requirement: DepsAndAssets multi-lane apply

For packages with technique `DepsAndAssets`, apply SHALL use the runtime-lane planner for the package’s ecosystem to obtain the planned set of PVs and KEYWORDS, materialize each PV that needs work (full or reuse path), commit each successful unit before the next, and perform exact-set prune of non-live ebuilds after all planned PVs succeed. Multi-PV ordering and failure isolation SHALL match multi-unit behavior (later unit failure does not roll back earlier committed units).

#### Scenario: Multiple planned PVs

- **WHEN** the plan contains two distinct PVs that both need materialization and both succeed
- **THEN** the first PV’s overlay commit exists in HEAD before the second PV’s mutation begins

### Requirement: Reuse path does not take assets publish critical section

When a planned PV is materialized via the reuse path (existing release asset), the program SHALL NOT hold the assets-repo git critical section solely for that PV’s materialization. Full-path publish for other packages or other PVs SHALL continue to serialize assets git/push/release as specified by `assets-publish`.

#### Scenario: Reuse while another package publishes

- **WHEN** package A reuses an existing release asset and package B needs a full assets publish
- **THEN** package A’s reuse work does not block on the assets git lock for commit/push/release of A’s PV

### Requirement: GitMvAndManifest leaves other versions

`GitMvAndManifest` apply behavior for non-selected ebuild versions in the package directory SHALL leave other non-selected versions in place. Exact-set pruning applies only to `DepsAndAssets` runtime-lane apply.

#### Scenario: Binary update does not delete siblings

- **WHEN** a `GitMvAndManifest` package directory has two ebuild versions and newest is renamed to a new remote PV
- **THEN** the non-selected older ebuild is left in place by that technique

### Requirement: Assets publish failure does not cancel sibling packages

A hard failure during assets commit, push, or release for one package SHALL NOT abort in-progress or pending apply attempts for other packages. Only that package’s overlay mutation SHALL be skipped.

#### Scenario: One assets failure others continue

- **WHEN** package A fails assets push and package B is still applying
- **THEN** package B may still complete successfully and the program continues until all selected packages are processed
