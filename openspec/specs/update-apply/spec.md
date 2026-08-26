# update-apply Specification

## Purpose

Package policy (hardcoded source + technique), applying updates (`GitMvAndManifest` and `DepsAndAssets`), dirty checks, assets publish coordination, and creating isolated GPG-signed commits in the overlay work tree.

## Requirements

### Requirement: Package policy model

The program SHALL model a package policy that binds a package key `category/package` to an update source and an update technique. The technique SHALL be one of: `GitMvAndManifest`; `DepsAndAssets` with an ecosystem specification (`Go` with optional go.mod subdirectory, `Npm`, `Bun`, `Cargo` with optional lock/package subdirectories, or `Sbcl`); or `Unsupported` with a human-readable reason. Policy lookup SHALL use a hardcoded map only. There SHALL NOT be a separate legacy Go-only technique alternative outside `DepsAndAssets`. This capability is the **canonical** home for the full hardcoded package set and techniques; other ecosystem specs SHALL NOT restate a partial policy map as authoritative.

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

The hardcoded policy map SHALL include an entry for every package known to ship in the mndz overlay that this manager automates, each with both a source and a technique. At minimum:

- `dev-lang/bun-bin`, `dev-lang/deno-bin`, and `dev-util/grok-build-bin` SHALL use `GitMvAndManifest`
- `dev-lisp/qlot` SHALL use `GitMvAndManifest` with GitHub source `fukamachi/qlot` and an empty tag prefix
- `dev-build/node-gyp` SHALL use `DepsAndAssets Npm` with npm source `node-gyp`
- `dev-db/dolt` (go.mod subdir `go`), `dev-util/beads` (root), `dev-util/crush` (root), and `dev-db/badger` (root) SHALL use `DepsAndAssets` with ecosystem `Go` and their existing GitHub sources (`dolthub/dolt`, `gastownhall/beads`, `charmbracelet/crush`, `dgraph-io/badger` with tag prefix `v`)
- `dev-util/openspec` SHALL use `DepsAndAssets Npm` with its npm source
- `dev-util/ralph-tui` and `dev-util/opencode` SHALL use `DepsAndAssets Bun` with GitHub sources (`subsy/ralph-tui`, `anomalyco/opencode`, tag prefix `v`)
- `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` SHALL use `DepsAndAssets Cargo` with GitHub sources (`jdx` / respective repos / tag prefix `v`); `usage` SHALL use package subdirectory `cli` when required for package metadata
- `dev-util/autolith` SHALL use `DepsAndAssets Sbcl` with GitHub source `luciusmagn/autolith` and tag prefix `v`

The map SHALL NOT include `dev-util/opencode-bin`. No package known solely for cargo CRATES list regeneration SHALL remain `Unsupported` for that reason alone. `dev-lisp/qlot` SHALL NOT be an overlay wait-edge provider for Autolith or other packages. `dev-build/node-gyp` SHALL NOT be an overlay wait-edge provider for opencode, ralph-tui, or other packages.

#### Scenario: Simple binary package is GitMvAndManifest

- **WHEN** policy is resolved for `dev-util/grok-build-bin`
- **THEN** the technique is `GitMvAndManifest`

#### Scenario: Go package is DepsAndAssets Go

- **WHEN** policy is resolved for `dev-util/beads`
- **THEN** the technique is `DepsAndAssets` with ecosystem `Go`

#### Scenario: badger is DepsAndAssets Go

- **WHEN** policy is resolved for `dev-db/badger`
- **THEN** the technique is `DepsAndAssets` with ecosystem `Go`
- **AND** the source is GitHub `dgraph-io` / `badger` with tag prefix `v`

#### Scenario: openspec is DepsAndAssets Npm

- **WHEN** policy is resolved for `dev-util/openspec`
- **THEN** the technique is `DepsAndAssets Npm`

#### Scenario: node-gyp is DepsAndAssets Npm

- **WHEN** policy is resolved for `dev-build/node-gyp`
- **THEN** the technique is `DepsAndAssets Npm`
- **AND** the source is npm `node-gyp`

#### Scenario: opencode is DepsAndAssets Bun

- **WHEN** policy is resolved for `dev-util/opencode`
- **THEN** the technique is `DepsAndAssets Bun`
- **AND** the source is GitHub `anomalyco/opencode` with tag prefix `v`

#### Scenario: mise is DepsAndAssets Cargo

- **WHEN** policy is resolved for `dev-util/mise`
- **THEN** the technique is `DepsAndAssets Cargo`

#### Scenario: usage package subdir

- **WHEN** policy is resolved for `dev-util/usage`
- **THEN** the technique is `DepsAndAssets Cargo` with package subdirectory `cli`

#### Scenario: autolith is DepsAndAssets Sbcl

- **WHEN** policy is resolved for `dev-util/autolith`
- **THEN** the technique is `DepsAndAssets Sbcl` and the source is GitHub `luciusmagn/autolith` with tag prefix `v`

#### Scenario: opencode-bin is absent

- **WHEN** policy is resolved for `dev-util/opencode-bin`
- **THEN** no policy entry is returned (unconfigured)

#### Scenario: qlot is GitMvAndManifest

- **WHEN** policy is resolved for `dev-lisp/qlot`
- **THEN** the technique is `GitMvAndManifest`
- **AND** the source is GitHub `fukamachi/qlot` with an empty tag prefix

### Requirement: Preserve Autolith template body on Sbcl apply

When rewriting a `DepsAndAssets Sbcl` ebuild for assets parameterization, SBCL atom alignment, KEYWORDS, or PV filename update, the program SHALL preserve template-owned body that is not those rewritten fields. This includes private-prefix install logic, wrapper generation, identity stamping, network-install disablement, core build steps, `IUSE`/`RESTRICT` test gating, and any non-assets `SRC_URI` companions or `FILESDIR`/`PATCHES` references present on the donor ebuild. The program SHALL NOT strip those constructs when parameterizing deps assets URLs to `${PV}`.

#### Scenario: Template survives PV bump

- **WHEN** apply updates autolith from `0.17.2` to `0.18.0` using the seed ebuild as donor
- **THEN** the new ebuild still contains the seed’s private layout / stamp / network-disable / test USE structure
- **AND** the deps assets URL uses `${PV}` for `0.18.0`

### Requirement: Overlay ceiling-provider GitMv commit after ensure when ensure ran

When `update` **will ensure** a materialize image in this run (at least one classified full-path unit will mutate, as specified by `ensure-materialize-image`) and the overlay wait-edge provider `dev-lang/bun-bin` is selected and needs GitMv work, the program SHALL complete bun-bin rename, `ebuild … manifest`, and package `egencache` as specified for `GitMvAndManifest`, and SHALL **delay** that unit’s signed overlay commit until ensure **finishes** (success or fail). After ensure finishes, the program SHALL create that signed overlay commit (GPG as already specified) before treating bun-bin as apply success, then admit withheld consumers. If ensure is **not** running in this run, bun-bin SHALL commit immediately after egencache as specified for other GitMv packages. A failed ensure SHALL NOT skip the bun-bin overlay commit when bun-bin file work succeeded.

Other GitMv packages SHALL keep commit-on-unit-success. The program SHALL NOT defer all overlay commits until every selected package has finished apply work.

#### Scenario: bun-bin commits after docker when ensure ran

- **WHEN** untargeted `update` needs bun-bin GitMv work and a full-path unit so ensure `docker build`s
- **THEN** bun-bin’s signed overlay commit is created after that ensure attempt finishes
- **AND** withheld Bun consumers are not admitted before that commit

#### Scenario: bun-bin still commits when docker fails

- **WHEN** bun-bin rename, Manifest, and egencache succeeded and ensure then fails
- **THEN** the program still creates the bun-bin signed overlay commit
- **AND** full-path units hard-fail as specified for failed ensure

#### Scenario: GitMv-only bun-bin commits after egencache

- **WHEN** the only needs-work package is `dev-lang/bun-bin` and no full-path unit requires ensure
- **THEN** bun-bin’s signed overlay commit is created after egencache without waiting on docker

### Requirement: Overlay qlot GitMv file work precedes qlot-layer docker

When `update` **will ensure** a materialize image in this run and the recipe will `emerge` `dev-lisp/qlot::mndz`, and overlay qlot is selected and needs `GitMvAndManifest` work, the program SHALL complete qlot rename, `ebuild … manifest`, and package `egencache` **before** that `docker build`. The program SHALL NOT delay qlot’s signed overlay commit until ensure finishes solely because ensure ran (qlot is not an overlay wait-edge provider). Autolith and other packages SHALL NOT be withheld on qlot. Independent GitMv that the image does not emerge may overlap ensure as already specified for bun-bin.

#### Scenario: qlot Manifest before docker; commit not delayed

- **WHEN** untargeted `update` needs GitMv work on `dev-lisp/qlot` and full-path work on Autolith, and the recipe will emerge overlay qlot
- **THEN** qlot rename, Manifest, and egencache complete before that `docker build`
- **AND** qlot’s signed overlay commit is not required to wait until ensure finishes
- **AND** Autolith is not presented as waiting on `dev-lisp/qlot`

### Requirement: Overlay node-gyp file work precedes node-gyp-layer docker

When `update` **will ensure** a materialize image in this run and the recipe will `emerge` `dev-build/node-gyp::mndz`, and overlay node-gyp is selected and needs `DepsAndAssets Npm` work (or overlay rewrite that changes the emerged PV), the program SHALL complete node-gyp overlay file work (`ebuild … manifest` and package `egencache` for the PV the recipe will emerge) **before** that `docker build`. The program SHALL NOT delay node-gyp’s signed overlay commit until ensure finishes solely because ensure ran (node-gyp is not an overlay wait-edge provider). opencode, ralph-tui, and other packages SHALL NOT be withheld on node-gyp. Independent GitMv that the image does not emerge may overlap ensure as already specified for bun-bin.

#### Scenario: node-gyp Manifest before docker; commit not delayed

- **WHEN** untargeted `update` needs NpmEco work on `dev-build/node-gyp` and full-path work on opencode, and the recipe will emerge overlay node-gyp
- **THEN** node-gyp Manifest and egencache for the emerged PV complete before that `docker build`
- **AND** node-gyp’s signed overlay commit is not required to wait until ensure finishes
- **AND** opencode is not presented as waiting on `dev-build/node-gyp`

### Requirement: Hypo-planned consumer overlay write asserts provider PV

Before overlay mutation of a `DepsAndAssets` unit whose working plan used hypothetical overlay ceiling-provider ceilings, the program SHALL apply the provider-PV assert specified by `overlay-apply-waves`. Mismatch is a unit hard-fail without overlay mutation.

#### Scenario: Ralph overlay write blocked on bun-bin PV mismatch

- **WHEN** ralph-tui would rewrite ebuilds assuming bun-bin `1.4.0` and overlay bun-bin newest non-live ebuild is not `1.4.0`
- **THEN** that unit hard-fails without rewriting ralph-tui ebuilds

### Requirement: GitMvAndManifest apply steps

For a package with technique `GitMvAndManifest` that is outdated, the apply procedure SHALL: (1) select the newest local ebuild by PV ordering; (2) verify the package’s non-live ebuilds have complete matching md5-cache as specified by the `md5-cache` capability (hard-fail with `gencache` / `gencache --force` recovery text when not); (3) verify involved paths are clean in git; (4) rename that ebuild file so its version component equals the remote PV (without inventing a revision); (5) run Portage `ebuild` on the new ebuild file with the `manifest` command from the package directory as the working directory; (6) run package-scoped Portage `egencache` for `category/package` as specified by `md5-cache`; (7) create a signed overlay git commit for that unit’s changed paths with message `category/package: version` where `version` is the remote PV string without a leading `v`, **immediately** after egencache except when the overlay ceiling-provider commit-after-ensure rule above applies. Success for that package SHALL mean the commit is present in the overlay worktree HEAD, not that paths are deferred for a later package-wide commit barrier covering unrelated packages.

When the ebuild filename changes, staged paths SHALL include at least: the **old** ebuild path (so the deletion is recorded), the **new** ebuild path, the package `Manifest`, and the affected `metadata/md5-cache/` paths for that package. Staging only the new ebuild and Manifest without the old path or without cache paths after a successful egencache is insufficient. Other ebuild versions in the same directory that were not selected as newest SHALL be left in place and SHALL NOT be staged by this update except as required for shared Manifest/cache package regeneration side effects already covered by package-scoped egencache path inclusion.

#### Scenario: Rename and manifest for new PV

- **WHEN** newest local ebuild is `deno-bin-2.9.2.ebuild` and remote PV is `2.9.3`
- **THEN** the ebuild is renamed to `deno-bin-2.9.3.ebuild` and `ebuild ./deno-bin-2.9.3.ebuild manifest` runs with cwd set to the package directory

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

- **WHEN** GitMv rename, `ebuild … manifest`, and package egencache succeed for a package that is not delaying commit until ensure
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

Package check, md5-cache consistency gate, dirty verification, vendor construction, ebuild rename/rewrite, and `ebuild … manifest` work SHALL be allowed to run concurrently across **admitted** packages, except that assets-repository git commit, push, and GitHub release publish for a shared assets worktree SHALL be mutually excluded, and package-scoped `egencache` together with overlay git index mutations (`git add` and `git commit`) SHALL be mutually excluded via an overlay critical section. Admission of selected packages to that concurrent phase-1 work SHALL honor overlay wait-edges as specified by `overlay-apply-waves`: a consumer withheld on an overlay ceiling provider SHALL NOT start phase-1 while that provider still needs work in this run. The program SHALL create each unit’s signed overlay commit immediately after that unit’s successful overlay mutation, manifest, egencache, and verification (commit-on-unit-success), except the overlay ceiling-provider GitMv commit-after-ensure rule. The program SHALL NOT defer all overlay commits until after every selected package has finished apply work. Global ordering of overlay commits by `category/package` is NOT required under concurrent apply; each commit SHALL include only paths belonging to that unit (including that unit’s md5-cache paths). Each overlay and assets commit SHALL sign with GPG (`git commit` with signing enabled); the program SHALL NOT create unsigned commits as a fallback. The program SHALL NOT read or store the GPG passphrase. Immediately before each signed overlay or assets commit, the program SHALL apply GPG sign readiness for that commit’s worktree (agent cache check; ready-prompt and unlock when cold; terminal pinentry environment) as specified by the gpg-sign-readiness capability. Signing failure, including readiness or unlock failure, SHALL be a hard failure for that unit and SHALL NOT leave an unsigned commit recorded as success.

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

#### Scenario: Withheld consumer does not share phase-1 with its provider

- **WHEN** bun-bin needs work and ralph-tui is withheld on bun-bin
- **THEN** ralph-tui phase-1 (vendor construction, ebuild rewrite, manifest) does not run concurrently with bun-bin phase-1

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

When more than one planned PV needs work in the same package apply, the program SHALL order those units so that **missing** planned PVs (no local non-live ebuild at that PV) are materialized **before** pure **content-fix** units (a local non-live ebuild at that PV exists but ebuild content, KEYWORDS, runtime field, and/or Manifest dist entry is inadequate). Within each of those two groups, ordering SHALL be stable by PV comparison (numeric components ascending). A PV that is missing SHALL be classified as missing for this order even if content-fix checks would also apply. This order SHALL keep discovery-time donor ebuild paths usable for new-PV template reads that fall back to an existing local ebuild, so a content-fix revision bump does not delete that donor path before missing PVs run.

#### Scenario: Multiple planned PVs

- **WHEN** the plan contains two distinct PVs that both need materialization and both succeed
- **THEN** the first PV’s overlay commit exists in HEAD before the second PV’s mutation begins

#### Scenario: Missing PV before content-fix revision bump

- **WHEN** a package has a local ebuild at PV `0.82.0` that needs a content-fix revision bump and the plan also requires a missing newer PV `0.88.0`
- **THEN** apply materializes `0.88.0` (including its overlay mutation using an existing local ebuild as template when needed) before the content-fix unit rewrites and replaces the `0.82.0` revision path
- **AND** the content-fix unit’s signed overlay commit does not run before the missing PV unit has completed its template read for overlay rewrite

#### Scenario: Only content-fix units keep PV order

- **WHEN** every planned PV that needs work already has a local non-live ebuild (content-fix only; no missing PVs)
- **THEN** units run in stable ascending PV order among those content-fix units

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

### Requirement: Apply outcomes independent of internal module layout

Apply behavior specified for `GitMvAndManifest` and `DepsAndAssets` (including hard-fail vs soft-skip classification, dirty-path checks, md5-cache gate before mutation, commit-on-unit-success, and assets publish coordination) SHALL hold regardless of how apply code is partitioned across library modules. Reorganizing apply source files SHALL NOT by itself change operator-visible update outcomes or exit-code policy.

#### Scenario: Module split does not change hard-fail folding

- **WHEN** update produces the same set of per-unit hard-fail and soft-skip outcomes before and after an internal apply module split
- **THEN** process hard-fail folding (exit failure only when any hard-fail occurred) remains the same

#### Scenario: Md5 gate still blocks before mutation

- **WHEN** a package would be updated but md5-cache is missing or mismatched for a non-live ebuild
- **THEN** the unit hard-fails without renaming or rewriting the ebuild, independent of which apply module implements the gate

### Requirement: Known apply hard-fail classes are identifiable

When an apply unit hard-fails for one of the following known classes, the operator-facing message SHALL identify the class of problem and remain actionable (recovery or next step when applicable):

1. Involved paths dirty in git  
2. Package md5-cache incomplete or mismatched (with gencache / gencache --force guidance as already required by md5-cache capability)  
3. Missing `assets-path` when DepsAndAssets requires assets publish  
4. Missing GitHub token when DepsAndAssets requires release publish  
5. Invalid package key  
6. Runtime-lane planning produced zero planned package PVs  
7. Missing donor or template ebuild path when a DepsAndAssets unit must read an existing ebuild to rewrite or create a planned PV  
8. `ebuild … manifest` failure attributable to sticky DISTDIR or distfiles ownership (operation not permitted on rename under distfiles), with guidance toward a user-owned manager distfiles path as specified by `manager-distfiles`
9. Overlay wait-edge refuse (unselected provider, plan-delta) or fail-closed provider latest-fetch, naming the provider, as specified by `overlay-apply-waves`
10. Overlay wait-edge provider hard-fail causing a withheld consumer to fail, naming the provider, as specified by `overlay-apply-waves`

When the selected template or donor ebuild path does not exist on disk at read time, the unit SHALL hard-fail with a message that identifies the missing template/donor (including package and path or planned PV when known) and SHALL NOT abort the process with an uncaught filesystem exception. Internal representation of these failures MAY be structured types, but the operator message SHALL NOT be an opaque empty string.

#### Scenario: Dirty paths message is identifiable

- **WHEN** a unit hard-fails because involved ebuild and/or Manifest paths are dirty
- **THEN** the hard-fail message indicates dirty involved paths (or equivalent clear wording)

#### Scenario: Missing assets-path message is identifiable

- **WHEN** a DepsAndAssets unit hard-fails because assets-path is not configured
- **THEN** the hard-fail message indicates that assets-path is required

#### Scenario: Missing donor template is hard-fail not crash

- **WHEN** a DepsAndAssets unit would read a template or donor ebuild path that does not exist
- **THEN** that unit hard-fails with a message identifying missing donor or template
- **AND** the process does not terminate solely via an uncaught openFile / does-not-exist IOException for that path

#### Scenario: Sticky distfiles manifest failure is identifiable

- **WHEN** a unit hard-fails because `ebuild … manifest` failed with an operation-not-permitted rename under distfiles
- **THEN** the hard-fail message indicates a sticky or ownership distfiles problem and points at configuring a private manager distfiles path

#### Scenario: Overlay refuse names the provider

- **WHEN** ralph-tui hard-fails because bun-bin is unselected and plan-delta holds
- **THEN** the hard-fail message names `dev-lang/bun-bin` and is not an opaque empty string

### Requirement: Ebuild manifest runs under manager distfiles environment

When apply runs Portage `ebuild` with the `manifest` command, that invocation SHALL use the effective manager distfiles environment required by `manager-distfiles` (`DISTDIR` set to the effective path; `GENTOO_MIRRORS` empty), not an unset environment that silently inherits a host sticky system DISTDIR by default.

#### Scenario: GitMv manifest uses manager DISTDIR

- **WHEN** a `GitMvAndManifest` unit runs `ebuild … manifest`
- **THEN** the ebuild process receives `DISTDIR` set to the effective manager distfiles path

#### Scenario: DepsAndAssets manifest uses manager DISTDIR

- **WHEN** a `DepsAndAssets` unit runs `ebuild … manifest`
- **THEN** the ebuild process receives `DISTDIR` set to the effective manager distfiles path
