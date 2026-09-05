## ADDED Requirements

### Requirement: Overlay write waits for atom closure

Before overlay mutation of a selected package (ebuild rewrite or GitMv rename, Manifest, egencache, signed commit), `update` apply SHALL enforce overlay-internal atom closure as specified by `overlay-atom-closure`: wait for an in-selection provider whose planned remaining PVs would satisfy an unsatisfied atom, otherwise hard-fail that package without overlay mutation. Language materialize and assets publish MAY overlap that provider. The wait SHALL occur before the overlay critical section and SHALL NOT be held inside it. Admission to phase-1 for ceiling wait-edges SHALL remain as specified by `overlay-apply-waves`; atom-closure wait SHALL NOT by itself withhold a package from phase-1 materialize.

#### Scenario: hk materialize overlaps usage

- **WHEN** untargeted `update` selects usage and hk, usage needs GitMv or DepsAndAssets work, and hk’s to-be-written ebuild is already satisfiable or will be after usage’s planned commit
- **THEN** hk MAY start language materialize while usage applies
- **AND** hk overlay mutation waits when current usage PVs would not satisfy the to-be-written ebuild

#### Scenario: Unsatisfied targeted consumer does not pull the provider

- **WHEN** `update dev-util/hk` would write an ebuild whose overlay-internal usage atom is unsatisfied and usage is not selected
- **THEN** hk hard-fails without overlay mutation
- **AND** usage is not added to the selection

## MODIFIED Requirements

### Requirement: DepsAndAssets multi-lane apply

For packages with technique `DepsAndAssets`, apply SHALL use the runtime-lane planner for the package’s ecosystem to obtain the planned set of PVs and KEYWORDS, materialize each PV that needs work (full or reuse path), commit each successful unit before the next, and perform prune of non-live ebuilds after all planned PVs succeed as specified by `runtime-lanes` and `overlay-atom-closure` (planned unique PVs union reverse-dep keep). Multi-PV ordering and failure isolation SHALL match multi-unit behavior (later unit failure does not roll back earlier committed units).

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

#### Scenario: Prune keeps a reverse-dep PV

- **WHEN** a DepsAndAssets provider’s unique planned set is one PV and a remaining consumer ebuild requires another on-disk provider PV by exact pin
- **THEN** after successful apply that extra PV remains

### Requirement: GitMvAndManifest leaves other versions

`GitMvAndManifest` apply behavior for non-selected ebuild versions in the package directory SHALL leave other non-selected versions in place. Exact-set pruning applies only to `DepsAndAssets` runtime-lane apply, as extended by `overlay-atom-closure` reverse-dep keep. GitMv rename of the newest ebuild SHALL honor the rename-away guard specified by `overlay-atom-closure`.

#### Scenario: Binary update does not delete siblings

- **WHEN** a `GitMvAndManifest` package directory has two ebuild versions and newest is renamed to a new remote PV
- **THEN** the non-selected older ebuild is left in place by that technique

#### Scenario: Rename-away of a required exact pin fails

- **WHEN** GitMv would rename the only matching provider PV away from an exact pin still required by a remaining consumer ebuild
- **THEN** the GitMv unit hard-fails without renaming

### Requirement: Parallel work then serial signed commits

Package check, md5-cache consistency gate, dirty verification, vendor construction, ebuild rename/rewrite, and `ebuild … manifest` work SHALL be allowed to run concurrently across **admitted** packages, except that assets-repository git commit, push, and GitHub release publish for a shared assets worktree SHALL be mutually excluded, and package-scoped `egencache` together with overlay git index mutations (`git add` and `git commit`) SHALL be mutually excluded via an overlay critical section. Admission of selected packages to that concurrent phase-1 work SHALL honor overlay wait-edges as specified by `overlay-apply-waves`: a consumer withheld on an overlay ceiling provider SHALL NOT start phase-1 while that provider still needs work in this run. Atom-closure wait specified by `overlay-atom-closure` SHALL NOT by itself withhold phase-1 materialize; it SHALL block overlay mutation only, and SHALL wait outside the overlay critical section. The program SHALL create each unit’s signed overlay commit immediately after that unit’s successful overlay mutation, manifest, egencache, and verification (commit-on-unit-success), except the overlay ceiling-provider GitMv commit-after-ensure rule. The program SHALL NOT defer all overlay commits until after every selected package has finished apply work. Global ordering of overlay commits by `category/package` is NOT required under concurrent apply; each commit SHALL include only paths belonging to that unit (including that unit’s md5-cache paths). Each overlay and assets commit SHALL sign with GPG (`git commit` with signing enabled); the program SHALL NOT create unsigned commits as a fallback. The program SHALL NOT read or store the GPG passphrase. Immediately before each signed overlay or assets commit, the program SHALL apply GPG sign readiness for that commit’s worktree (agent cache check; ready-prompt and unlock when cold; terminal pinentry environment) as specified by the gpg-sign-readiness capability. Signing failure, including readiness or unlock failure, SHALL be a hard failure for that unit and SHALL NOT leave an unsigned commit recorded as success.

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

#### Scenario: Atom-closure wait does not hold the overlay lock

- **WHEN** a consumer is waiting for a provider signed commit so its to-be-written ebuild will be atom-closed
- **THEN** the consumer is not inside the overlay critical section while waiting
- **AND** the provider can still obtain that critical section
