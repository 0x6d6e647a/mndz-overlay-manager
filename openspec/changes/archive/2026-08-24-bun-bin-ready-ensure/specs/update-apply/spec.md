## ADDED Requirements

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

### Requirement: Hypo-planned consumer overlay write asserts provider PV

Before overlay mutation of a `DepsAndAssets` unit whose working plan used hypothetical overlay ceiling-provider ceilings, the program SHALL apply the provider-PV assert specified by `overlay-apply-waves`. Mismatch is a unit hard-fail without overlay mutation.

#### Scenario: Ralph overlay write blocked on bun-bin PV mismatch

- **WHEN** ralph-tui would rewrite ebuilds assuming bun-bin `1.4.0` and overlay bun-bin newest non-live ebuild is not `1.4.0`
- **THEN** that unit hard-fails without rewriting ralph-tui ebuilds

## MODIFIED Requirements

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
