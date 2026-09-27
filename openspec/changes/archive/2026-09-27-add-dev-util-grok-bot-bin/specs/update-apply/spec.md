# Spec Delta

## MODIFIED Requirements

### Requirement: Hardcoded policy covers known overlay packages

The hardcoded policy map SHALL include an entry for every package known to ship in the mndz overlay that this manager automates, each with both a source and a technique. At minimum:

- `dev-lang/bun-bin`, `dev-lang/deno-bin`, `dev-util/grok-build-bin`, and `dev-util/grok-bot-bin` SHALL use `GitMvAndManifest`
- `dev-lisp/qlot` SHALL use `GitMvAndManifest` with GitHub source `fukamachi/qlot` and an empty tag prefix
- `dev-build/node-gyp` SHALL use `DepsAndAssets Npm` with npm source `node-gyp`
- `dev-db/dolt` (go.mod subdir `go`), `dev-util/beads` (root), `dev-util/crush` (root), and `dev-db/badger` (root) SHALL use `DepsAndAssets` with ecosystem `Go` and their existing GitHub sources (`dolthub/dolt`, `gastownhall/beads`, `charmbracelet/crush`, `dgraph-io/badger` with tag prefix `v`)
- `dev-util/openspec` SHALL use `DepsAndAssets Npm` with its npm source
- `dev-util/ralph-tui` and `dev-util/opencode` SHALL use `DepsAndAssets Bun` with GitHub sources (`subsy/ralph-tui`, `anomalyco/opencode`, tag prefix `v`)
- `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` SHALL use `DepsAndAssets Cargo` with GitHub sources (`jdx` / respective repos / tag prefix `v`); `usage` SHALL use package subdirectory `cli` when required for package metadata
- `dev-util/autolith` SHALL use `DepsAndAssets Sbcl` with GitHub source `luciusmagn/autolith` and tag prefix `v`

The map SHALL NOT include `dev-util/opencode-bin`. No package known solely for cargo CRATES list regeneration SHALL remain `Unsupported` for that reason alone. `dev-lisp/qlot` SHALL NOT be an overlay wait-edge provider for Autolith or other packages. `dev-build/node-gyp` SHALL NOT be an overlay wait-edge provider for opencode, ralph-tui, or other packages. `dev-util/grok-bot-bin` SHALL NOT be an overlay wait-edge provider and SHALL NOT be emerged by the materialize image.

#### Scenario: Simple binary package is GitMvAndManifest

- **WHEN** policy is resolved for `dev-util/grok-build-bin`
- **THEN** the technique is `GitMvAndManifest`

#### Scenario: Grok Bot is GitMvAndManifest

- **WHEN** policy is resolved for `dev-util/grok-bot-bin`
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

## ADDED Requirements

### Requirement: Grok Bot GitMv rewrites the commit pin

Before `ebuild manifest` on a `dev-util/grok-bot-bin` `GitMvAndManifest` apply, the program SHALL fetch both stable download feeds again and SHALL replace the ebuild's `GROK_BOT_COMMIT` assignment with the feed `commitSha`. The rename to the remote PV SHALL still happen as specified for `GitMvAndManifest`. The rest of the ebuild body, including `IUSE`, `RDEPEND`, `SRC_URI` shape, and install layout, SHALL be preserved.

Apply SHALL hard-fail the package without overlay mutation when any of the following holds: either feed's `version` differs from the planned remote PV; the two feeds' `commitSha` values differ; either `debUrl` is not `https://downloads.cursor.com/grokbot/stable/<commitSha>/linux/<x64|arm64>/grok-bot_<version>_<amd64|arm64>.deb` for that arch and version; or the ebuild has no `GROK_BOT_COMMIT` assignment to replace.

#### Scenario: Commit moves with the version

- **WHEN** apply bumps `grok-bot-bin` from `0.61.0` to `0.62.0` and both feeds report version `0.62.0`, commit `abc123`, and `debUrl` values ending in `grok-bot_0.62.0_amd64.deb` and `grok-bot_0.62.0_arm64.deb` under that commit
- **THEN** the new ebuild is `grok-bot-bin-0.62.0.ebuild`
- **AND** its `GROK_BOT_COMMIT` assignment is `abc123`
- **AND** `IUSE` and the `/opt/Grok Bot` install layout are unchanged

#### Scenario: Feed moved past the planned version

- **WHEN** the planned remote PV is `0.62.0` and a feed fetched at apply time reports `0.63.0`
- **THEN** that package hard-fails
- **AND** the overlay ebuild is not renamed

#### Scenario: Deb filename drifted

- **WHEN** a feed's `debUrl` does not end in `grok-bot_<version>_<arch>.deb` under that feed's `commitSha`
- **THEN** that package hard-fails
- **AND** `ebuild manifest` does not run for it
