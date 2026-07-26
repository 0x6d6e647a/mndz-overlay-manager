## MODIFIED Requirements

### Requirement: Hardcoded Go packages use DepsAndAssets Go

The hardcoded policy map SHALL set `DepsAndAssets` with ecosystem `Go` for `dev-db/dolt` (subdir `go`), `dev-util/beads` (root), `dev-util/crush` (root), and `dev-db/badger` (root), each with their existing GitHub update sources (`dolthub/dolt`, `gastownhall/beads`, `charmbracelet/crush`, `dgraph-io/badger` with tag prefix `v`). Those packages SHALL NOT remain `Unsupported` solely for vendor assets.

#### Scenario: dolt technique

- **WHEN** policy is resolved for `dev-db/dolt`
- **THEN** the technique is `DepsAndAssets` with ecosystem `Go` and go.mod subdirectory `go`

#### Scenario: crush technique

- **WHEN** policy is resolved for `dev-util/crush`
- **THEN** the technique is `DepsAndAssets` with ecosystem `Go` and go.mod at repository root

#### Scenario: badger technique

- **WHEN** policy is resolved for `dev-db/badger`
- **THEN** the technique is `DepsAndAssets` with ecosystem `Go` and go.mod at repository root
- **AND** the update source is GitHub `dgraph-io` / `badger` with tag prefix `v`

## ADDED Requirements

### Requirement: Preserve non-assets companion SRC_URI on Go rewrite

When rewriting a Go package ebuild for assets parameterization, BDEPEND alignment, KEYWORDS, or PV filename update, the program SHALL preserve non-assets `SRC_URI` entries that do not use the mndz-overlay-assets release download marker. This includes USE-conditional blocks such as a fixed jemalloc upstream tarball. The program SHALL NOT drop, freeze-rewrite, or re-home those companion URIs when parameterizing vendor assets URLs to `${PV}`.

#### Scenario: jemalloc companion survives parameterization

- **WHEN** the template ebuild contains a vendor assets URL with a frozen version and a `jemalloc? ( https://github.com/jemalloc/jemalloc/releases/download/5.3.0/jemalloc-5.3.0.tar.bz2 )` (or equivalent) companion URI
- **THEN** after Go assets parameterization the companion jemalloc URI is still present unchanged
- **AND** the vendor assets URL uses `${PV}` in the mndz-overlay-assets path

#### Scenario: Only assets URL is parameterized

- **WHEN** the ebuild has both a GitHub source archive URI and an assets vendor URI and a jemalloc companion URI
- **THEN** parameterization changes only the assets vendor URI components that encode the package version under mndz-overlay-assets
