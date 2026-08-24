## ADDED Requirements

### Requirement: Overlay qlot GitMv file work precedes qlot-layer docker

When `update` **will ensure** a materialize image in this run and the recipe will `emerge` `dev-lisp/qlot::mndz`, and overlay qlot is selected and needs `GitMvAndManifest` work, the program SHALL complete qlot rename, `ebuild … manifest`, and package `egencache` **before** that `docker build`. The program SHALL NOT delay qlot’s signed overlay commit until ensure finishes solely because ensure ran (qlot is not an overlay wait-edge provider). Autolith and other packages SHALL NOT be withheld on qlot. Independent GitMv that the image does not emerge may overlap ensure as already specified for bun-bin.

#### Scenario: qlot Manifest before docker; commit not delayed

- **WHEN** untargeted `update` needs GitMv work on `dev-lisp/qlot` and full-path work on Autolith, and the recipe will emerge overlay qlot
- **THEN** qlot rename, Manifest, and egencache complete before that `docker build`
- **AND** qlot’s signed overlay commit is not required to wait until ensure finishes
- **AND** Autolith is not presented as waiting on `dev-lisp/qlot`

## MODIFIED Requirements

### Requirement: Hardcoded policy covers known overlay packages

The hardcoded policy map SHALL include an entry for every package known to ship in the mndz overlay that this manager automates, each with both a source and a technique. At minimum:

- `dev-lang/bun-bin`, `dev-lang/deno-bin`, and `dev-util/grok-build-bin` SHALL use `GitMvAndManifest`
- `dev-lisp/qlot` SHALL use `GitMvAndManifest` with GitHub source `fukamachi/qlot` and an empty tag prefix
- `dev-db/dolt` (go.mod subdir `go`), `dev-util/beads` (root), `dev-util/crush` (root), and `dev-db/badger` (root) SHALL use `DepsAndAssets` with ecosystem `Go` and their existing GitHub sources (`dolthub/dolt`, `gastownhall/beads`, `charmbracelet/crush`, `dgraph-io/badger` with tag prefix `v`)
- `dev-util/openspec` SHALL use `DepsAndAssets Npm` with its npm source
- `dev-util/ralph-tui` and `dev-util/opencode` SHALL use `DepsAndAssets Bun` with GitHub sources (`subsy/ralph-tui`, `anomalyco/opencode`, tag prefix `v`)
- `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` SHALL use `DepsAndAssets Cargo` with GitHub sources (`jdx` / respective repos / tag prefix `v`); `usage` SHALL use package subdirectory `cli` when required for package metadata
- `dev-util/autolith` SHALL use `DepsAndAssets Sbcl` with GitHub source `luciusmagn/autolith` and tag prefix `v`

The map SHALL NOT include `dev-util/opencode-bin`. No package known solely for cargo CRATES list regeneration SHALL remain `Unsupported` for that reason alone. `dev-lisp/qlot` SHALL NOT be an overlay wait-edge provider for Autolith or other packages.

#### Scenario: Simple binary package is GitMvAndManifest

- **WHEN** policy is resolved for `dev-util/grok-build-bin`
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
