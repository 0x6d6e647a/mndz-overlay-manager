## ADDED Requirements

### Requirement: Vendor and BDEPEND for each planned PV

When materializing a Go tree-lane target PV for `GoVendorAndAssets`, the program SHALL clone the tag formed by the source tag prefix plus that PV, run the existing host Go vs `go.mod` gate, build and publish the vendor tarball for that PV, and ensure the overlay ebuild for that PV has BDEPEND `>=dev-lang/go-<go.mod go version>:=` and assets SRC_URI parameterization as already specified for Go vendor packages. Host Go sufficiency remains evaluated per clone/PV and SHALL NOT select which PV the planner chooses.

#### Scenario: Lower PV still vendors when host satisfies its go.mod

- **WHEN** planned PV `0.82.0` has `go 1.26.3` and host Go is `1.26.4`
- **THEN** vendor construction for `0.82.0` may proceed under the host gate

#### Scenario: Planner not driven by host

- **WHEN** host Go is newer than the Gentoo tilde ceiling
- **THEN** planned target PVs remain bounded by tree ceilings, not by host Go

### Requirement: Overlay KEYWORDS for multi-PV Go packages

For ebuilds written or updated under Go tree-lane apply, KEYWORDS SHALL use only tilde arch forms (`~amd64`, `~arm64`) assembled from lane membership for that PV as defined by `go-tree-lanes`. The program SHALL set or replace the KEYWORDS line (or equivalent) so it matches the plan for that PV.

#### Scenario: Dual-arch single PV

- **WHEN** one PV serves both amd64 and arm64 lanes
- **THEN** that ebuild’s KEYWORDS include both `~amd64` and `~arm64`

## MODIFIED Requirements

### Requirement: Temp clone at release tag

For `GoVendorAndAssets` apply of a given target PV (including each Go tree-lane planned PV), the program SHALL clone the package’s GitHub source into a system temporary directory, check out the tag formed by the source tag prefix plus that target PV (for example prefix `v` and PV `0.76.0` → tag `v0.76.0`), and remove the temporary clone when that PV’s apply attempt finishes (success or failure). The program SHALL NOT require a pre-existing long-lived checkout of the upstream project.

#### Scenario: Clone uses target PV tag

- **WHEN** the planned target PV is `0.82.0` and the tag prefix is `v`
- **THEN** the temporary clone checks out tag `v0.82.0`
