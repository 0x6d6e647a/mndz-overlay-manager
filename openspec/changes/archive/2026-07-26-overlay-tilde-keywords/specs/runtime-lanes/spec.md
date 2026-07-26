## MODIFIED Requirements

### Requirement: Collapse KEYWORDS across all runtime arches

The planner SHALL collapse lane targets to the set of unique package PVs. For each unique PV and each arch that appears in any lane definition for the runtime, planned KEYWORDS SHALL include that arch when any plain or tilde lane for that arch targets the PV; else omit that arch.

For **all** `DepsAndAssets` ecosystems (Go, Cargo, npm, Bun, and any other ecosystem that uses this collapse path), every included arch token SHALL be the **tilde** form (`~arch`). Plain versus tilde lanes affect which PV is selected and which arches appear, not bare versus tilde stability marking on the overlay ebuild. Bare arch tokens SHALL NOT appear in planned KEYWORDS.

This matches mndz-overlay policy (GURU-aligned): overlay packages are testing-only; there is no arch-team stabilization. Runtime plain/tilde ceilings remain as defined elsewhere in this capability for candidate selection only.

#### Scenario: Multi-arch single PV

- **WHEN** all lanes that have targets select package PV `1.6.0` across amd64 and arm64
- **THEN** the planned ebuild set is `{1.6.0}` with KEYWORDS including `~amd64` and `~arm64` and not bare `amd64` or bare `arm64`

#### Scenario: Plain lane does not emit bare arch

- **WHEN** only the plain amd64 lane targets package PV `0.84.0` (any ecosystem using this collapse)
- **THEN** planned KEYWORDS for that PV include `~amd64` and do not include bare `amd64`

#### Scenario: Cargo plain membership still tilde

- **WHEN** plain and tilde rust lanes both target the same Cargo package PV on amd64
- **THEN** planned KEYWORDS include `~amd64` and do not include bare `amd64`
