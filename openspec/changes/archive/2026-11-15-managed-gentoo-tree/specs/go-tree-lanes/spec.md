# Spec Delta

## ADDED Requirements

### Requirement: Gentoo dev-lang/go ceilings from the managed tree

The program SHALL scan non-live `go-*.ebuild` files (excluding `9999` and other live versions) under `dev-lang/go` in the managed tree specified by `gentoo-tree`, parse PV and KEYWORDS, discover every arch present in those KEYWORDS, and compute per arch a plain ceiling (max PV with the bare arch token) and a tilde ceiling (max PV with `~arch` or the bare token). An unavailable tree or unreadable package dir SHALL fail discovery.

#### Scenario: Tilde ceiling at least as new as plain

- **WHEN** gentoo has `go-1.26.3` with KEYWORDS including bare `amd64` and `go-1.26.4` with only `~amd64` among amd64-visible versions
- **THEN** the amd64 plain ceiling is `1.26.3` and the amd64 tilde ceiling is at least `1.26.4`

#### Scenario: Live ebuild ignored

- **WHEN** `go-9999.ebuild` exists alongside versioned go ebuilds
- **THEN** ceiling computation does not use `9999` as a maximum

#### Scenario: Managed tree unavailable

- **WHEN** the managed tree is missing and could not be created
- **THEN** ceiling discovery reports failure and does not invent ceilings

#### Scenario: Non-amd64-arm64 arch

- **WHEN** non-live go ebuilds include KEYWORDS with an arch other than amd64 and arm64
- **THEN** ceiling discovery includes plain and/or tilde ceilings for that arch

#### Scenario: Shared semantics for other ecosystems

- **WHEN** planning a non-Go `DepsAndAssets` package
- **THEN** ceiling and lane semantics follow `runtime-lanes`, and this requirement remains the Go ceiling source

## REMOVED Requirements

### Requirement: Gentoo dev-lang/go ceilings via portageq

**Reason**: Go ceilings now come from the manager-owned Gentoo tree, not from the host tree located with `portageq`. The rule against a non-`portageq` tree path was an early scope cut.

**Migration**: Replaced by "Gentoo dev-lang/go ceilings from the managed tree"; ceiling semantics are unchanged.
