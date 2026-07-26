## MODIFIED Requirements

### Requirement: Overlay KEYWORDS for multi-PV Go packages

For ebuilds written or updated under Go runtime-lane apply, KEYWORDS SHALL match the planned per-arch membership for that PV as defined by `go-tree-lanes` / `runtime-lanes` over all arches present on the Go runtime package, using **tilde** arch tokens only (`~amd64`, never bare `amd64`), consistent with the shared overlay tilde-only policy for all `DepsAndAssets` ecosystems. The program SHALL set or replace the KEYWORDS line (or equivalent) so it matches the plan for that PV. The program SHALL NOT write bare arch KEYWORDS tokens for overlay Go packages even when a plain lane targets the PV. The program SHALL NOT limit KEYWORDS assembly to a hard-coded amd64/arm64-only set when other arches appear on `dev-lang/go`.

#### Scenario: Dual-arch single PV with plain lanes

- **WHEN** one PV serves both amd64 and arm64 plain lanes (and any corresponding tilde lanes that select the same PV)
- **THEN** that ebuild’s KEYWORDS include `~amd64` and `~arm64` and do not include bare `amd64` or bare `arm64`

#### Scenario: Tilde-only arch on overlay write

- **WHEN** a planned PV has tilde-only membership for amd64 and no plain amd64 membership
- **THEN** that ebuild’s KEYWORDS include `~amd64` and do not include bare `amd64`
