## MODIFIED Requirements

### Requirement: Parallel work then serial signed commits

Package check, md5-cache consistency gate, dirty verification, vendor construction, and `ebuild … manifest` work SHALL be allowed to run concurrently across **admitted** packages, except that assets-repository git commit, push, and GitHub release publish for a shared assets worktree SHALL be mutually excluded, and package-scoped `egencache` together with overlay git index mutations (`git add` and `git commit`) SHALL be mutually excluded via an overlay critical section. Ebuild rename, ebuild content write, and ebuild deletion MAY overlap manifest, vendor construction, and language materialize of other admitted packages. An observation of overlay ebuild names and bodies for atom closure, reverse-dep keep, or an ensure floor, together with the ebuild rename, content write, or deletion that publishes the decision from that observation, SHALL be mutually excluded across packages. That ebuild exclusion SHALL NOT include `ebuild … manifest`, package `egencache`, overlay git index mutations, the atom-closure wait, language materialize, assets publish, or image ensure's `docker build`. `outdated`, package check, and the plan phase SHALL NOT take the ebuild exclusion. Admission of selected packages to that concurrent phase-1 work SHALL honor overlay wait-edges as specified by `overlay-apply-waves`: a consumer withheld on an overlay ceiling provider SHALL NOT start phase-1 while that provider still needs work in this run. Atom-closure wait specified by `overlay-atom-closure` SHALL NOT by itself withhold phase-1 materialize; it SHALL block overlay mutation only, and SHALL wait outside the overlay critical section and outside the ebuild exclusion. The program SHALL create each unit’s signed overlay commit immediately after that unit’s successful overlay mutation, manifest, egencache, and verification (commit-on-unit-success), except the overlay ceiling-provider GitMv commit-after-ensure rule. The program SHALL NOT defer all overlay commits until after every selected package has finished apply work. Global ordering of overlay commits by `category/package` is NOT required under concurrent apply; each commit SHALL include only paths belonging to that unit (including that unit’s md5-cache paths). Each overlay and assets commit SHALL sign with GPG (`git commit` with signing enabled); the program SHALL NOT create unsigned commits as a fallback. The program SHALL NOT read or store the GPG passphrase. Immediately before each signed overlay or assets commit, the program SHALL apply GPG sign readiness for that commit’s worktree (agent cache check; ready-prompt and unlock when cold; terminal pinentry environment) as specified by the gpg-sign-readiness capability. Signing failure, including readiness or unlock failure, SHALL be a hard failure for that unit and SHALL NOT leave an unsigned commit recorded as success.

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

## ADDED Requirements

### Requirement: Overlay ebuild observation is coherent and fails closed

When apply observes overlay ebuild names and bodies for atom closure, reverse-dep keep, or an ensure floor, that observation SHALL be a single set: every included ebuild is the complete body under the name in that set. The program SHALL NOT treat an ebuild as absent because a read failed after the name was listed, and then continue the decision. If a listed overlay ebuild cannot be read, the unit performing the observation SHALL hard-fail without overlay mutation. The operator message SHALL name the missing or unreadable path and SHALL NOT be an uncaught filesystem exception. Other selected packages SHALL continue. Image ensure SHALL fail before `docker build` when its own overlay floor observation cannot be read, and that failure SHALL name the path.

The ebuild rename, content write, or deletion that publishes the decision SHALL be part of the same exclusion hold as the observation that justified it. A later observation SHALL be taken after an atom-closure wait, and the publish SHALL happen only when that later observation shows the package's overlay-internal atoms satisfied.

#### Scenario: Reader sees a complete ebuild on either side of a rename

- **WHEN** package A reads package B's ebuild for atom closure or reverse-dep keep while package B renames that ebuild
- **THEN** A observes either B's complete pre-rename body or B's complete post-rename body
- **AND** A does not treat B's ebuild as absent solely because the path disappeared between listing and reading
- **AND** the process does not abort with an uncaught missing-file exception

#### Scenario: Unreadable ebuild hard-fails the observer

- **WHEN** an atom-closure, reverse-dep keep, or ensure-floor observation cannot read an overlay ebuild path it listed
- **THEN** the observing unit or image ensure hard-fails
- **AND** the message names that path
- **AND** the observing package does not rename, rewrite, or delete an ebuild from that failed observation
- **AND** other selected packages may still succeed

#### Scenario: Publish uses the observation that found the atoms satisfied

- **WHEN** a package's overlay-internal atoms are unsatisfied until a selected provider finishes, and a later observation shows those atoms satisfied
- **THEN** the package publishes its ebuild only in the same exclusion hold as that satisfied observation
- **AND** another package's ebuild rename, content write, or deletion does not land between that observation and this publish
