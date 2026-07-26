## MODIFIED Requirements

### Requirement: Hardcoded policy covers known overlay packages

The hardcoded policy map SHALL include an entry for every package known to ship in the mndz overlay that this manager automates, each with both a source and a technique. At minimum, `dev-lang/bun-bin`, `dev-lang/deno-bin`, and `dev-util/grok-build-bin` SHALL use `GitMvAndManifest`. At minimum, `dev-db/dolt`, `dev-util/beads`, and `dev-util/crush` SHALL use `DepsAndAssets` with ecosystem `Go`. At minimum, `dev-util/openspec` SHALL use `DepsAndAssets Npm` and both `dev-util/ralph-tui` and `dev-util/opencode` SHALL use `DepsAndAssets Bun`. At minimum, `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` SHALL use `DepsAndAssets` with ecosystem `Cargo`. The map SHALL NOT include `dev-util/opencode-bin`. No package known solely for cargo CRATES list regeneration SHALL remain `Unsupported` for that reason alone.

#### Scenario: Simple binary package is GitMvAndManifest

- **WHEN** policy is resolved for `dev-util/grok-build-bin`
- **THEN** the technique is `GitMvAndManifest`

#### Scenario: Go package is DepsAndAssets Go

- **WHEN** policy is resolved for `dev-util/beads`
- **THEN** the technique is `DepsAndAssets` with ecosystem `Go`

#### Scenario: openspec is DepsAndAssets Npm

- **WHEN** policy is resolved for `dev-util/openspec`
- **THEN** the technique is `DepsAndAssets Npm`

#### Scenario: opencode is DepsAndAssets Bun

- **WHEN** policy is resolved for `dev-util/opencode`
- **THEN** the technique is `DepsAndAssets Bun`

#### Scenario: mise is DepsAndAssets Cargo

- **WHEN** policy is resolved for `dev-util/mise`
- **THEN** the technique is `DepsAndAssets Cargo`

#### Scenario: opencode-bin is absent

- **WHEN** policy is resolved for `dev-util/opencode-bin`
- **THEN** no policy entry is returned (unconfigured)

### Requirement: GitMvAndManifest apply steps

For a package with technique `GitMvAndManifest` that is outdated, the apply procedure SHALL: (1) select the newest local ebuild by PV ordering; (2) verify the package’s non-live ebuilds have complete matching md5-cache as specified by the `md5-cache` capability (hard-fail with `gencache` / `gencache --force` recovery text when not); (3) verify involved paths are clean in git; (4) rename that ebuild file so its version component equals the remote PV (without inventing a revision); (5) run Portage `ebuild` on the new ebuild file with the `manifest` command from the package directory as the working directory; (6) run package-scoped Portage `egencache` for `category/package` as specified by `md5-cache`; (7) immediately create a signed overlay git commit for that unit’s changed paths with message `category/package: version` where `version` is the remote PV string without a leading `v`. Success for that package SHALL mean the commit is present in the overlay worktree HEAD, not that paths are deferred for a later commit phase.

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

- **WHEN** GitMv rename, `ebuild … manifest`, and package egencache succeed
- **THEN** the program creates the signed overlay commit for that package before treating the package as apply success
- **AND** it does not leave those paths pending a later package-wide commit barrier

#### Scenario: Missing cache blocks GitMv before rename

- **WHEN** the package would be updated but md5-cache is missing for a non-live ebuild
- **THEN** the unit hard-fails without renaming the ebuild
