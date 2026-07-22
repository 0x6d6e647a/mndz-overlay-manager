## MODIFIED Requirements

### Requirement: Overlay KEYWORDS for multi-PV Go packages

For ebuilds written or updated under Go tree-lane apply, KEYWORDS SHALL match the planned per-arch bare/`~` membership for that PV as defined by `go-tree-lanes` (plain lane → bare arch; tilde-only → `~arch`; bare covers plain and tilde consumers on that arch). The program SHALL set or replace the KEYWORDS line (or equivalent) so it matches the plan for that PV. The program SHALL NOT force tilde-only KEYWORDS when a plain lane targets the PV.

#### Scenario: Dual-arch single PV with plain lanes

- **WHEN** one PV serves both amd64 and arm64 plain lanes (and any corresponding tilde lanes that select the same PV)
- **THEN** that ebuild’s KEYWORDS include bare `amd64` and bare `arm64`

#### Scenario: Tilde-only arch on overlay write

- **WHEN** a planned PV has tilde-only membership for amd64 and no plain amd64 membership
- **THEN** that ebuild’s KEYWORDS include `~amd64` and do not include bare `amd64`
