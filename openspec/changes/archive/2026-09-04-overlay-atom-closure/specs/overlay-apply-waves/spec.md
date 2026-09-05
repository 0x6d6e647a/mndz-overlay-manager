## MODIFIED Requirements

### Requirement: Overlay wait-edges follow technique ceiling source

For `DepsAndAssets` packages whose runtime-lane ceiling source is a package in the configured overlay, that overlay package SHALL be the overlay wait-edge **provider** and the `DepsAndAssets` package SHALL be the **consumer**. Today that mapping is: ecosystem `Bun` waits on `dev-lang/bun-bin`. Ecosystems whose ceilings come from the gentoo repository (Go, Npm, Cargo, Sbcl) SHALL NOT create overlay wait-edges. The program SHALL NOT parse ebuild `DEPEND`, `RDEPEND`, or `BDEPEND` to discover these **ceiling wait-edges**, and SHALL NOT require a second per-package edge map for them. Parsing `DEPEND*` for overlay-internal atom closure is specified by `overlay-atom-closure` and SHALL NOT create overlay wait-edges. Adding a package whose technique is `DepsAndAssets Bun` SHALL create the bun-bin wait-edge without a separate edge-table edit.

#### Scenario: ralph waits on bun-bin

- **WHEN** policy for `dev-util/ralph-tui` is `DepsAndAssets Bun` and `dev-lang/bun-bin` is in the `update` selection
- **THEN** ralph-tui has an overlay wait-edge on bun-bin

#### Scenario: mise has no overlay wait-edge

- **WHEN** policy for `dev-util/mise` is `DepsAndAssets Cargo`
- **THEN** mise has no overlay wait-edge

#### Scenario: New Bun package inherits the edge

- **WHEN** a newly configured overlay package uses `DepsAndAssets Bun`
- **THEN** that package waits on `dev-lang/bun-bin` without a separate edge-table entry

#### Scenario: Atom-closure parse does not create a Cargo wait-edge

- **WHEN** `dev-util/hk` ebuild `RDEPEND` contains `dev-util/usage`
- **THEN** hk has no overlay wait-edge on usage solely because of that atom
