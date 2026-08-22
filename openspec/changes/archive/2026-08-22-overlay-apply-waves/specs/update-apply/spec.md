## MODIFIED Requirements

### Requirement: Parallel work then serial signed commits

Package check, md5-cache consistency gate, dirty verification, vendor construction, ebuild rename/rewrite, and `ebuild … manifest` work SHALL be allowed to run concurrently across **admitted** packages, except that assets-repository git commit, push, and GitHub release publish for a shared assets worktree SHALL be mutually excluded, and package-scoped `egencache` together with overlay git index mutations (`git add` and `git commit`) SHALL be mutually excluded via an overlay critical section. Admission of selected packages to that concurrent phase-1 work SHALL honor overlay wait-edges as specified by `overlay-apply-waves`: a consumer withheld on an overlay ceiling provider SHALL NOT start phase-1 while that provider still needs work in this run. The program SHALL create each unit’s signed overlay commit immediately after that unit’s successful overlay mutation, manifest, egencache, and verification (commit-on-unit-success). The program SHALL NOT defer all overlay commits until after every selected package has finished apply work. Global ordering of overlay commits by `category/package` is NOT required under concurrent apply; each commit SHALL include only paths belonging to that unit (including that unit’s md5-cache paths). Each overlay and assets commit SHALL sign with GPG (`git commit` with signing enabled); the program SHALL NOT create unsigned commits as a fallback. The program SHALL NOT read or store the GPG passphrase. Immediately before each signed overlay or assets commit, the program SHALL apply GPG sign readiness for that commit’s worktree (agent cache check; ready-prompt and unlock when cold; terminal pinentry environment) as specified by the gpg-sign-readiness capability. Signing failure, including readiness or unlock failure, SHALL be a hard failure for that unit and SHALL NOT leave an unsigned commit recorded as success.

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
