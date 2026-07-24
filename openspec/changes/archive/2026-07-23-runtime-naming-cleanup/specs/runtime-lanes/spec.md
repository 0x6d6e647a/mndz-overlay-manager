## ADDED Requirements

### Requirement: Runtime-lane planning is multi-ecosystem

Runtime-lane planning for `DepsAndAssets` packages SHALL apply to all supported ecosystems (Go, Npm, Bun, and Cargo), not only Go. Operator-facing lane labels SHALL identify the actual runtime package atom for the ecosystem in use (for example `dev-lang/go`, `net-libs/nodejs`, `dev-lang/bun-bin`, or the cargo/rust runtime atom used by planning), not a hard-coded Go atom for non-Go packages.

#### Scenario: Npm labels use nodejs atom

- **WHEN** an outdated or update success line is emitted for a `DepsAndAssets Npm` package on a nodejs lane
- **THEN** the label identifies `net-libs/nodejs` (with arch/tier form) rather than `dev-lang/go`

#### Scenario: Cargo planning uses runtime-lane machinery

- **WHEN** a `DepsAndAssets Cargo` package is planned
- **THEN** planning uses the same runtime-lane concepts (ceilings, candidates, lane targets, collapse, zero-PV hard-fail) as other DepsAndAssets ecosystems
