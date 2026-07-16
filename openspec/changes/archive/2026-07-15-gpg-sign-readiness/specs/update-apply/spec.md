## MODIFIED Requirements

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
