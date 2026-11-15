# Spec Delta

## MODIFIED Requirements

### Requirement: Strong fingerprint invalidates stale local state

A cache entry SHALL be used only when its age is within the effective TTL (when the cache is enabled), the operator did not request refresh for the run, and its fingerprint matches the package’s current state: the set of non-live local PVs, a stable identifier of the configured update source, and a content hash of the package’s non-live ebuild file contents and Manifest content when present. When any fingerprint component differs, the program SHALL treat the entry as a miss and perform live check or plan work for that package.

For a successful `DepsAndAssets` (deps payload) entry whose technique has an overlay ceiling provider as specified by `overlay-apply-waves`, the fingerprint SHALL also include that overlay provider package’s fingerprint computed the same way (non-live local PVs, that provider’s configured update source id, content hash of that provider’s non-live ebuild file contents and Manifest when present). A deps entry that lacks the overlay-provider fingerprint component SHALL be a miss. Every successful `DepsAndAssets` (deps payload) entry SHALL also include the managed Gentoo tree identity (commit id, as specified by `gentoo-tree`) it was planned against; a deps entry whose tree identity differs from the current tree, or that lacks one, SHALL be a miss. Individual Gentoo-sourced runtime packages SHALL NOT be fingerprinted separately. GitMv latest-only entries SHALL NOT require an overlay-provider fingerprint component.

#### Scenario: Local PV change is a miss

- **WHEN** a cache entry exists within TTL but the package’s non-live local PVs differ from the entry fingerprint
- **THEN** the program does not use that entry for remote or plan data

#### Scenario: Ebuild content change is a miss

- **WHEN** a cache entry exists within TTL but the content hash of package ebuilds or Manifest differs
- **THEN** the program does not use that entry for remote or plan data

#### Scenario: Overlay bun-bin tree change misses ralph deps entry

- **WHEN** a valid TTL deps cache entry exists for `dev-util/ralph-tui` and overlay `dev-lang/bun-bin` non-live ebuilds or Manifest change
- **THEN** the program does not use that ralph-tui entry for the runtime-lane plan

#### Scenario: Missing overlay-provider fingerprint is a miss

- **WHEN** a deps cache entry for a `DepsAndAssets Bun` package has no overlay-provider fingerprint component
- **THEN** the program treats the entry as a miss

#### Scenario: Tree commit change misses deps entry

- **WHEN** a valid TTL deps cache entry for a `DepsAndAssets Go` package was planned against tree commit `A` and the managed tree is now at commit `B`
- **THEN** the program does not use that entry for the runtime-lane plan

#### Scenario: GitMv entry ignores tree commit

- **WHEN** a valid TTL latest-only entry exists for a GitMv package and the managed tree commit changed
- **THEN** the program uses that entry
