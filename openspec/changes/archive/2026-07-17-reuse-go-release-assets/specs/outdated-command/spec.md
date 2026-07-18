## MODIFIED Requirements

### Requirement: Go tree-lane outdated reporting

For each package whose technique is `GoVendorAndAssets`, the `outdated` check SHALL use the Go tree-lane planner (Gentoo `dev-lang/go` ceilings, upstream candidates, per-lane target PVs) instead of comparing only newest local PV to a single latest remote. For each lane that has a target PV and is not already satisfied by a local non-live ebuild at that PV with adequate content for that tip (ebuild present; content-fix rules for assets URI / BDEPEND / KEYWORDS; and Manifest vendor DIST present for that PV’s vendor tarball as defined by `go-vendor-assets`), the program SHALL write a stdout line of the form `category/package vFROM -> vTO (dev-lang/go …)` using the lane label from `go-tree-lanes`. Split and converge mapping SHALL follow: when one local version maps to multiple new targets, emit one line per target with the same `vFROM`; when multiple locals converge to one target, emit one line per local `vFROM` to that `vTO`. Packages that are fully satisfied for all lanes with targets SHALL NOT produce outdated lines for those lanes.

When the reason a present planned PV is still unsatisfied is **only** overlay content or Manifest incompleteness (the local ebuild for that PV already exists) rather than a missing PV ebuild, the program SHALL append the token ` [assets reusable]` to that outdated line so operators can see that apply may complete without re-vendoring if the release asset already exists. Missing planned PV ebuilds SHALL use the normal line without requiring a GitHub probe during `outdated`.

#### Scenario: Uncollapsed two-lane gap

- **WHEN** local has only `0.80.0` and the plan targets `0.82.0` for `(dev-lang/go amd64)` and `0.84.0` for `(dev-lang/go ~amd64)` (other lanes satisfied or absent)
- **THEN** stdout includes `… v0.80.0 -> v0.82.0 (dev-lang/go amd64)` and `… v0.80.0 -> v0.84.0 (dev-lang/go ~amd64)`

#### Scenario: Converge report shape

- **WHEN** locals are `0.80.0` and `0.82.0` and the plan collapses to a single target `0.84.0` for remaining lanes
- **THEN** stdout includes lines mapping `v0.80.0 -> v0.84.0` and `v0.82.0 -> v0.84.0` with appropriate lane labels

#### Scenario: Fully planned package is silent

- **WHEN** local ebuilds exactly match the planned unique PV set and content and Manifest fixes are not required
- **THEN** the program writes no outdated stdout line for that package

#### Scenario: Same-PV Manifest fix labeled reusable

- **WHEN** planned PV `0.84.0` is present locally with ebuild content that still needs Manifest vendor DIST completion (or other overlay-only content fix) for a lane
- **THEN** the outdated line for that lane includes the substring ` [assets reusable]`
