# Spec Delta

## MODIFIED Requirements

### Requirement: Hardcoded policy covers known overlay packages

The hardcoded policy map SHALL include an entry for every package known to ship in the mndz overlay that this manager automates, each with both a source and a technique. At minimum:

- `dev-lang/bun-bin`, `dev-lang/deno-bin`, `dev-util/grok-build-bin`, and `dev-util/grok-bot-bin` SHALL use `GitMvAndManifest`
- `net-analyzer/witen-warden-bin` SHALL use `GitMvAndManifest` with Http source `https://www.witenlabs.com/api/releases/warden/version`
- `dev-lisp/qlot` SHALL use `GitMvAndManifest` with GitHub source `fukamachi/qlot` and an empty tag prefix
- `dev-build/node-gyp` SHALL use `DepsAndAssets Npm` with npm source `node-gyp`
- `dev-db/dolt` (go.mod subdir `go`), `dev-util/beads` (root), `dev-util/crush` (root), and `dev-db/badger` (root) SHALL use `DepsAndAssets` with ecosystem `Go` and their existing GitHub sources (`dolthub/dolt`, `gastownhall/beads`, `charmbracelet/crush`, `dgraph-io/badger` with tag prefix `v`)
- `dev-util/openspec` SHALL use `DepsAndAssets Npm` with its npm source
- `dev-util/ralph-tui` and `dev-util/opencode` SHALL use `DepsAndAssets Bun` with GitHub sources (`subsy/ralph-tui`, `anomalyco/opencode`, tag prefix `v`)
- `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` SHALL use `DepsAndAssets Cargo` with GitHub sources (`jdx` / respective repos / tag prefix `v`); `usage` SHALL use package subdirectory `cli` when required for package metadata
- `dev-util/autolith` SHALL use `DepsAndAssets Sbcl` with GitHub source `luciusmagn/autolith` and tag prefix `v`

The map SHALL NOT include `dev-util/opencode-bin`. No package known solely for cargo CRATES list regeneration SHALL remain `Unsupported` for that reason alone. `dev-lisp/qlot` SHALL NOT be an overlay wait-edge provider for Autolith or other packages. `dev-build/node-gyp` SHALL NOT be an overlay wait-edge provider for opencode, ralph-tui, or other packages. `dev-util/grok-bot-bin` SHALL NOT be an overlay wait-edge provider and SHALL NOT be emerged by the materialize image. `net-analyzer/witen-warden-bin` SHALL NOT be an overlay wait-edge provider and SHALL NOT be emerged by the materialize image.

#### Scenario: Simple binary package is GitMvAndManifest

- **WHEN** policy is resolved for `dev-util/grok-build-bin`
- **THEN** the technique is `GitMvAndManifest`

#### Scenario: Grok Bot is GitMvAndManifest

- **WHEN** policy is resolved for `dev-util/grok-bot-bin`
- **THEN** the technique is `GitMvAndManifest`

#### Scenario: Warden is GitMvAndManifest

- **WHEN** policy is resolved for `net-analyzer/witen-warden-bin`
- **THEN** the technique is `GitMvAndManifest`
- **AND** the source is Http `https://www.witenlabs.com/api/releases/warden/version`

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

### Requirement: Warden GitMv preserves the ebuild body

A `GitMvAndManifest` apply for `net-analyzer/witen-warden-bin` SHALL rename the newest ebuild to the remote PV and SHALL NOT rewrite the ebuild body. Both `SRC_URI` shapes, `IUSE`, dependencies, and the install layout SHALL be unchanged aside from `${PV}` expansion at build time.

#### Scenario: Bump from 0.1.17 keeps the distfile templates

- **WHEN** apply bumps `witen-warden-bin` from `0.1.17` to `0.1.19`
- **THEN** the new ebuild is `witen-warden-bin-0.1.19.ebuild`
- **AND** its body still contains `witen-warden-${PV}-linux-amd64-glibc.tar.gz` and `witen-warden_${PV}-1_amd64.deb`
- **AND** `IUSE` and the `/usr/bin/warden` install layout are unchanged
