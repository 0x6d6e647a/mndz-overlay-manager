## MODIFIED Requirements

### Requirement: Unique ebuild set and KEYWORDS assembly

The planner SHALL collapse lane targets to the set of unique package PVs. For each unique PV, the planned ebuild KEYWORDS SHALL be assembled **per arch** (`amd64`, `arm64`) from the tiers of lanes that target that PV:

- If at least one **plain** lane for that arch targets the PV, KEYWORDS SHALL include the bare arch token (e.g. `amd64`) and SHALL NOT include `~arch` for that arch.
- Else if at least one **tilde** lane for that arch targets the PV, KEYWORDS SHALL include `~arch` (e.g. `~amd64`).
- Else that arch SHALL be omitted from KEYWORDS.

Bare package KEYWORDS for an arch SHALL be treated as covering both plain and tilde consumers on that arch (no second `~arch` token is required when plain membership is present). When all successful lanes share one PV, the planned set SHALL contain exactly that one PV with the union of per-arch tokens under the rules above.

#### Scenario: Single PV collapse with plain membership

- **WHEN** all four lanes select package PV `0.84.0`
- **THEN** the planned ebuild set is exactly `{0.84.0}` and KEYWORDS include bare `amd64` and bare `arm64` (and do not require `~amd64` or `~arm64`)

#### Scenario: Arch-divergent PVs with plain membership

- **WHEN** both amd64 lanes (plain and tilde) select `0.84.0` and both arm64 lanes select `0.82.0`
- **THEN** the planned set is `{0.84.0, 0.82.0}` with `0.84.0` KEYWORDS containing bare `amd64` (not requiring `arm64` or `~arm64`) and `0.82.0` KEYWORDS containing bare `arm64` (not requiring `amd64` or `~amd64`)

#### Scenario: Tilde-only membership on one arch

- **WHEN** only the amd64 tilde lane targets PV `0.84.0` and no plain amd64 lane targets that PV
- **THEN** that ebuild’s KEYWORDS include `~amd64` and do not include bare `amd64`

#### Scenario: Staggered plain vs tilde on the same arch family

- **WHEN** amd64 plain targets `0.75.0`, amd64 tilde targets `0.82.0`, and both arm64 lanes target `0.82.0`
- **THEN** `0.75.0` KEYWORDS contain bare `amd64` only (for these arches) and `0.82.0` KEYWORDS contain `~amd64` and bare `arm64`

#### Scenario: At most four ebuilds

- **WHEN** all four lanes select pairwise distinct package PVs
- **THEN** the planned set contains four PVs
