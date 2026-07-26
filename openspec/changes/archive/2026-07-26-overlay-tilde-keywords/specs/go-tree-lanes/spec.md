## MODIFIED Requirements

### Requirement: Unique ebuild set and KEYWORDS assembly

The planner SHALL collapse lane targets to the set of unique package PVs. For each unique PV, the planned ebuild KEYWORDS SHALL be assembled **per arch** for every arch that participates in Go runtime lanes from the tiers of lanes that target that PV:

- If at least one **plain** or **tilde** lane for that arch targets the PV, KEYWORDS SHALL include the **tilde** arch token (e.g. `~amd64`) and SHALL NOT include the bare arch token (e.g. `amd64`).
- Else that arch SHALL be omitted from KEYWORDS.

Plain versus tilde lanes SHALL continue to determine which package PV each lane selects and thus which arches appear on each PV; they SHALL NOT produce bare KEYWORDS tokens on overlay ebuilds. This matches the shared `runtime-lanes` overlay tilde-only KEYWORDS policy (all `DepsAndAssets` ecosystems). When all successful lanes share one PV, the planned set SHALL contain exactly that one PV with the union of per-arch **tilde** tokens under the rules above. Assembly SHALL NOT be limited to a hard-coded amd64/arm64-only arch set when other arches have lanes.

#### Scenario: Single PV collapse with plain membership

- **WHEN** all successful lanes select package PV `0.84.0` for amd64 and arm64
- **THEN** the planned ebuild set is exactly `{0.84.0}` and KEYWORDS include `~amd64` and `~arm64` and do not include bare `amd64` or bare `arm64`

#### Scenario: Arch-divergent PVs with plain membership

- **WHEN** both amd64 lanes (plain and tilde) select `0.84.0` and both arm64 lanes select `0.82.0`
- **THEN** the planned set is `{0.84.0, 0.82.0}` with `0.84.0` KEYWORDS containing `~amd64` (not requiring `~arm64`) and `0.82.0` KEYWORDS containing `~arm64` (not requiring `~amd64`)
- **AND** neither ebuild’s KEYWORDS include bare arch tokens

#### Scenario: Tilde-only membership on one arch

- **WHEN** only the amd64 tilde lane targets PV `0.84.0` and no plain amd64 lane targets that PV
- **THEN** that ebuild’s KEYWORDS include `~amd64` and do not include bare `amd64`

#### Scenario: Staggered plain vs tilde on the same arch family

- **WHEN** amd64 plain targets `0.75.0`, amd64 tilde targets `0.82.0`, and both arm64 lanes target `0.82.0`
- **THEN** `0.75.0` KEYWORDS contain `~amd64` only (for these arches) and `0.82.0` KEYWORDS contain `~amd64` and `~arm64`
- **AND** no bare `amd64` or bare `arm64` tokens appear
