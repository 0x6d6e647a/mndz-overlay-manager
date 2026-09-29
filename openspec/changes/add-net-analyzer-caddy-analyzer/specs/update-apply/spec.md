# update-apply Delta

## MODIFIED Requirements

### Requirement: Hardcoded policy covers known overlay packages

The hardcoded policy map SHALL include an entry for every package known to ship in the mndz overlay that this manager automates, each with both a source and a technique. At minimum:

- `dev-lang/bun-bin`, `dev-lang/deno-bin`, `dev-util/grok-build-bin`, and `dev-util/grok-bot-bin` SHALL use `GitMvAndManifest`
- `net-analyzer/witen-warden-bin` SHALL use `GitMvAndManifest` with Http source `https://www.witenlabs.com/api/releases/warden/version`
- `dev-lisp/qlot` SHALL use `GitMvAndManifest` with GitHub source `fukamachi/qlot` and an empty tag prefix
- `dev-build/node-gyp` SHALL use `DepsAndAssets Npm` with npm source `node-gyp`
- `dev-db/dolt` (go.mod subdir `go`), `dev-util/beads` (root), `dev-util/crush` (root), `dev-db/badger` (root), and `dev-util/gastown` (root) SHALL use `DepsAndAssets` with ecosystem `Go` and their existing GitHub sources (`dolthub/dolt`, `gastownhall/beads`, `charmbracelet/crush`, `dgraph-io/badger`, `gastownhall/gastown` with tag prefix `v`)
- `net-analyzer/caddy-analyzer` SHALL use `DepsAndAssets` with ecosystem `Go`, repository-root `go.mod`, GitHub source `lenny-ts/caddy-analyzer`, tag prefix `v`, and runtime-lane architectures restricted to `amd64`, `arm`, and `arm64`
- `dev-util/openspec` SHALL use `DepsAndAssets Npm` with its npm source
- `dev-util/ralph-tui` and `dev-util/opencode` SHALL use `DepsAndAssets Bun` with GitHub sources (`subsy/ralph-tui`, `anomalyco/opencode`, tag prefix `v`)
- `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` SHALL use `DepsAndAssets Cargo` with GitHub sources (`jdx` / respective repos / tag prefix `v`); `usage` SHALL use package subdirectory `cli` when required for package metadata
- `dev-util/autolith` SHALL use `DepsAndAssets Sbcl` with GitHub source `luciusmagn/autolith` and tag prefix `v`

The map SHALL NOT include `dev-util/opencode-bin`. No package known solely for cargo CRATES list regeneration SHALL remain `Unsupported` for that reason alone. `dev-lisp/qlot` SHALL NOT be an overlay wait-edge provider for Autolith or other packages. `dev-build/node-gyp` SHALL NOT be an overlay wait-edge provider for opencode, ralph-tui, or other packages. `dev-util/grok-bot-bin` SHALL NOT be an overlay wait-edge provider and SHALL NOT be emerged by the materialize image. `net-analyzer/witen-warden-bin` SHALL NOT be an overlay wait-edge provider and SHALL NOT be emerged by the materialize image. `dev-util/gastown` SHALL NOT be an overlay wait-edge provider and SHALL NOT be emerged by the materialize image.

`net-analyzer/caddy-analyzer` SHALL NOT be an overlay wait-edge provider and SHALL NOT be emerged by the materialize image.

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

#### Scenario: gastown is DepsAndAssets Go

- **WHEN** policy is resolved for `dev-util/gastown`
- **THEN** the technique is `DepsAndAssets` with ecosystem `Go` and no go.mod subdirectory
- **AND** the source is GitHub `gastownhall` / `gastown` with tag prefix `v`

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

#### Scenario: Caddy analyzer follows the Go update path

- **WHEN** policy is resolved for `net-analyzer/caddy-analyzer`
- **THEN** the technique is `DepsAndAssets` Go with no go.mod subdirectory
- **AND** the source is GitHub `lenny-ts/caddy-analyzer` with tag prefix `v`
- **AND** runtime lanes consider only `amd64`, `arm`, and `arm64` from the discovered Go runtime arches
- **AND** the package does not become a materialize-image dependency or an overlay wait-edge provider

#### Scenario: Caddy analyzer target does not select a version

- **WHEN** `outdated` or `update` selects `net-analyzer/caddy-analyzer`, or the unambiguous bare name `caddy-analyzer`
- **THEN** both tokens resolve to the same inventory key using existing target rules
- **AND** target PVs are selected from comparable upstream tags and the permitted Go runtime lanes
- **AND** the commands do not interpret a supplied version as a CLI version pin
