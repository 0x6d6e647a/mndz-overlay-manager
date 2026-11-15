# Spec Delta

## MODIFIED Requirements

### Requirement: Runtime ceiling source per ecosystem

For `DepsAndAssets` planning, the library SHALL compute plain and tilde version ceilings per architecture for the package’s runtime dependency package(s):

- **Go:** managed Gentoo tree (`gentoo-tree`), package directory `dev-lang/go`
- **Npm:** managed Gentoo tree, package directory `net-libs/nodejs`
- **Bun:** configured overlay path (`mndz-overlay-path`), package directory `dev-lang/bun-bin`
- **Cargo:** managed Gentoo tree, package directories `dev-lang/rust` and `dev-lang/rust-bin`, combined with U1 max per arch×tier as specified below
- **Sbcl:** managed Gentoo tree, package directory `dev-lisp/sbcl`
- **Uv:** managed Gentoo tree, package directory `dev-lang/python`. Slot ceilings and the chosen slot atom SHALL follow the Uv slot requirements in this capability
- **Pdm:** managed Gentoo tree, package directory `dev-lang/python`. Slot ceilings and the chosen slot atom SHALL follow the Pdm slot requirements in this capability

The library SHALL scan non-live ebuilds only (excluding live/`9999` versions). If a required runtime package directory is missing or unreadable, ceiling discovery SHALL fail with an error suitable for the caller.

#### Scenario: Bun ceilings from overlay

- **WHEN** planning a `DepsAndAssets Bun` package and overlay contains `dev-lang/bun-bin` ebuilds
- **THEN** ceilings are computed from those overlay ebuilds, not from gentoo

#### Scenario: Node ceilings from gentoo

- **WHEN** planning a `DepsAndAssets Npm` package
- **THEN** ceilings are computed from gentoo `net-libs/nodejs` non-live ebuilds

#### Scenario: Cargo ceilings from rust union

- **WHEN** planning a `DepsAndAssets Cargo` package
- **THEN** ceilings are computed from gentoo `dev-lang/rust` and `dev-lang/rust-bin` non-live ebuilds combined per U1 max

#### Scenario: Sbcl ceilings from gentoo

- **WHEN** planning a `DepsAndAssets Sbcl` package
- **THEN** ceilings are computed from gentoo `dev-lisp/sbcl` non-live ebuilds

#### Scenario: Uv ceilings from python slots

- **WHEN** planning a `DepsAndAssets Uv` package
- **THEN** ceilings are computed from non-live gentoo `dev-lang/python` ebuilds as slots, not from profile `PYTHON_TARGETS`

#### Scenario: Pdm ceilings from python slots

- **WHEN** planning a `DepsAndAssets Pdm` package
- **THEN** ceilings are computed from non-live gentoo `dev-lang/python` ebuilds as slots, not from profile `PYTHON_TARGETS`

#### Scenario: Gentoo ceilings ignore the host tree

- **WHEN** planning a `DepsAndAssets Go` package and the host has a Gentoo tree whose `dev-lang/go` ebuilds differ from the managed tree
- **THEN** ceilings are computed from the managed tree’s `dev-lang/go` ebuilds
