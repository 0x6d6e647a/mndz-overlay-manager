# Spec Delta

## MODIFIED Requirements

### Requirement: GitMvAndManifest apply steps

For a package with technique `GitMvAndManifest` that is outdated, the apply procedure SHALL: (1) select the newest local ebuild by PV ordering; (2) verify the package’s non-live ebuilds have complete matching md5-cache as specified by the `md5-cache` capability (hard-fail with `gencache` / `gencache --force` recovery text when not); (3) verify involved paths are clean in git; (4) rename that ebuild file so its version component equals the remote PV (without inventing a revision); (5) run Portage `ebuild` on the new ebuild file with the `manifest` command from the package directory as the working directory; (6) run package-scoped Portage `egencache` for `category/package` as specified by `md5-cache`; (7) pass the unit's smoke gate as specified by `update-smoke-gate`; (8) create a signed overlay git commit for that unit’s changed paths with message `category/package: version` where `version` is the remote PV string without a leading `v`, **immediately** after the gate passes except when the overlay ceiling-provider commit-after-ensure rule above applies; (9) push the overlay as specified by `overlay-push`. Success for that package SHALL mean the commit is present in the overlay worktree HEAD and pushed, not that paths are deferred for a later package-wide commit barrier covering unrelated packages.

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

- **WHEN** GitMv rename, `ebuild … manifest`, package egencache, and the smoke gate succeed for a package that is not delaying commit until ensure
- **THEN** the program creates the signed overlay commit for that package before treating the package as apply success
- **AND** it does not leave those paths pending a later package-wide commit barrier

#### Scenario: GitMv gate failure is not committed

- **WHEN** GitMv rename, `ebuild … manifest`, and package egencache succeed and the smoke gate fails
- **THEN** no overlay commit is created for that unit and the unit is held as specified by `held-units`

#### Scenario: Missing cache blocks GitMv before rename

- **WHEN** the package would be updated but md5-cache is missing for a non-live ebuild
- **THEN** the unit hard-fails without renaming the ebuild

### Requirement: Parallel work then serial signed commits

Package check, md5-cache consistency gate, dirty verification, vendor construction, and `ebuild … manifest` work SHALL be allowed to run concurrently across **admitted** packages, except that assets-repository git commit, push, and GitHub release publish for a shared assets worktree SHALL be mutually excluded, and package-scoped `egencache` together with overlay git index mutations (`git add` and `git commit`) and the overlay push SHALL be mutually excluded via an overlay critical section. Smoke gates SHALL run one at a time as specified by `update-smoke-gate` and SHALL NOT hold the overlay critical section. Ebuild rename, ebuild content write, and ebuild deletion MAY overlap manifest, vendor construction, and language materialize of other admitted packages. An observation of overlay ebuild names and bodies for atom closure, reverse-dep keep, or an ensure floor, together with the ebuild rename, content write, or deletion that publishes the decision from that observation, SHALL be mutually excluded across packages. That ebuild exclusion SHALL NOT include `ebuild … manifest`, package `egencache`, overlay git index mutations, the atom-closure wait, language materialize, assets publish, or image ensure's `docker build`. `outdated`, package check, and the plan phase SHALL NOT take the ebuild exclusion. Admission of selected packages to that concurrent phase-1 work SHALL honor overlay wait-edges as specified by `overlay-apply-waves`: a consumer withheld on an overlay ceiling provider SHALL NOT start phase-1 while that provider still needs work in this run. Atom-closure wait specified by `overlay-atom-closure` SHALL NOT by itself withhold phase-1 materialize; it SHALL block overlay mutation only, and SHALL wait outside the overlay critical section and outside the ebuild exclusion. The program SHALL create each unit’s signed overlay commit immediately after that unit’s successful overlay mutation, manifest, egencache, smoke gate, assets publish when applicable, and published-asset verification (commit-on-unit-success), except the overlay ceiling-provider GitMv commit-after-ensure rule. The program SHALL NOT defer all overlay commits until after every selected package has finished apply work. Global ordering of overlay commits by `category/package` is NOT required under concurrent apply; each commit SHALL include only paths belonging to that unit (including that unit’s md5-cache paths). Each overlay and assets commit SHALL sign with GPG (`git commit` with signing enabled); the program SHALL NOT create unsigned commits as a fallback. The program SHALL NOT read or store the GPG passphrase. Immediately before each signed overlay or assets commit, the program SHALL apply GPG sign readiness for that commit’s worktree (agent cache check; unlock when cold; terminal pinentry environment) as specified by the gpg-sign-readiness capability. Signing failure, including readiness or unlock failure, SHALL be a hard failure for that unit and SHALL NOT leave an unsigned commit recorded as success.

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
- **THEN** only one overlay `egencache`/`git add`/`git commit`/`git push` critical section runs at a time

#### Scenario: Gate does not hold the overlay lock

- **WHEN** unit A is in its smoke gate and unit B is ready to commit
- **THEN** B may commit and push while A's gated run is active

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

#### Scenario: Atom-closure wait does not hold the overlay lock

- **WHEN** a consumer is waiting for a provider signed commit so its to-be-written ebuild will be atom-closed
- **THEN** the consumer is not inside the overlay critical section while waiting
- **AND** the consumer is not inside the ebuild exclusion while waiting
- **AND** the provider can still obtain that critical section and can still publish its ebuild

#### Scenario: Manifest overlaps another package's ebuild publish

- **WHEN** admitted package A is running `ebuild … manifest` and admitted package B renames or rewrites its own ebuild
- **THEN** those two steps may overlap
- **AND** the process does not abort with an uncaught missing-file exception from B's ebuild

#### Scenario: Independent GitMv packages both commit

- **WHEN** untargeted `update` admits two independent `GitMvAndManifest` packages that both need work and `--jobs` is greater than 1
- **THEN** each package that succeeds has its own signed overlay commit
- **AND** the process does not abort because one package listed the other's ebuild and then found that path gone

#### Scenario: Check and plan stay outside the ebuild exclusion

- **WHEN** the operator runs `outdated` or the plan phase of `update` with `--jobs` greater than 1
- **THEN** per-package check and plan work still runs concurrently up to that jobs limit
- **AND** that work does not take the apply ebuild exclusion

### Requirement: Overlay ceiling-provider GitMv commit after ensure when ensure ran

When `update` **will ensure** a materialize image in this run (at least one classified full-path unit will mutate, as specified by `ensure-materialize-image`) and the overlay wait-edge provider `dev-lang/bun-bin` is selected and needs GitMv work, the program SHALL complete bun-bin rename, `ebuild … manifest`, and package `egencache` as specified for `GitMvAndManifest`, and SHALL **delay** that unit’s signed overlay commit until ensure **finishes** (success or fail) and bun-bin's smoke gate has passed. After both, the program SHALL create that signed overlay commit (GPG as already specified) before treating bun-bin as apply success, then admit withheld consumers. If ensure is **not** running in this run, bun-bin SHALL commit immediately after its gate passes as specified for other GitMv packages. A failed ensure SHALL NOT skip the bun-bin overlay commit when bun-bin file work and its gate succeeded. A failed bun-bin gate SHALL prevent the commit regardless of ensure.

Other GitMv packages SHALL keep commit-on-unit-success. The program SHALL NOT defer all overlay commits until every selected package has finished apply work.

#### Scenario: bun-bin commits after docker when ensure ran

- **WHEN** untargeted `update` needs bun-bin GitMv work and a full-path unit so ensure `docker build`s, and bun-bin's gate passes
- **THEN** bun-bin’s signed overlay commit is created after that ensure attempt finishes and after the gate passes
- **AND** withheld Bun consumers are not admitted before that commit

#### Scenario: bun-bin still commits when docker fails

- **WHEN** bun-bin rename, Manifest, egencache, and gate succeeded and ensure then fails
- **THEN** the program still creates the bun-bin signed overlay commit
- **AND** full-path units hard-fail as specified for failed ensure

#### Scenario: bun-bin gate failure prevents its commit

- **WHEN** bun-bin's gate fails while ensure is running
- **THEN** no bun-bin overlay commit is created and bun-bin is held as specified by `held-units`

#### Scenario: GitMv-only bun-bin commits after egencache

- **WHEN** the only needs-work package is `dev-lang/bun-bin` and no full-path unit requires ensure
- **THEN** bun-bin’s signed overlay commit is created after egencache and its gate without waiting on docker

### Requirement: Half-applied package warning

When a unit hard-fails after the ebuild was renamed or rewritten but before a successful signed overlay commit (for example `ebuild manifest` failure, `egencache` failure, or signing failure after mutation), and the unit is not held as specified by `held-units`, the program SHALL log an error and a warning that the package directory may be left dirty or half-applied so a later dirty check or md5-cache consistency gate can explain retry failures, and SHALL mention that cache reconciliation may require `gencache` or `gencache --force` when ebuild and cache disagree. A held unit SHALL NOT produce this warning.

#### Scenario: Manifest failure after rename warns dirty

- **WHEN** rename succeeds and `ebuild … manifest` fails
- **THEN** the program logs an error for the failure and a warning that the package tree may be dirty

#### Scenario: egencache failure after manifest warns cache repair

- **WHEN** rename and manifest succeed and package egencache fails
- **THEN** the program logs an error and a warning that mentions possible need for `gencache` / `gencache --force` before retry

#### Scenario: Held unit does not warn dirty

- **WHEN** a unit fails its gate and is held and rolled back
- **THEN** the program does not log the half-applied warning for that unit

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
11. Smoke gate failure, naming the failed run, its stage or skip reason, and its log, as specified by `update-smoke-gate`
12. Gate dependency cycle, naming every package in the cycle
13. Published-asset verification failure, naming the URL and the mismatch, as specified by `assets-publish`
14. Overlay push failure, naming the `git push` the operator can run, as specified by `overlay-push`
15. Unit stopped because publishing halted, naming the push failure that halted it

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

#### Scenario: Gate failure is identifiable

- **WHEN** a unit hard-fails because its gated run failed in its build stage
- **THEN** the hard-fail message says the smoke gate failed, names `fail: build`, and names the run's log path

#### Scenario: Halted unit is identifiable

- **WHEN** a unit is stopped because an earlier overlay push failed
- **THEN** the hard-fail message says publishing halted and names the unit whose push failed
