## ADDED Requirements

### Requirement: Go tree-lane outdated reporting

For each package whose technique is `GoVendorAndAssets`, the `outdated` check SHALL use the Go tree-lane planner (Gentoo `dev-lang/go` ceilings, upstream candidates, per-lane target PVs) instead of comparing only newest local PV to a single latest remote. For each lane that has a target PV and is not already satisfied by a local non-live ebuild at that PV with adequate content for that tip (ebuild present; content-fix rules for assets URI / BDEPEND may mark a present PV as still outdated), the program SHALL write a stdout line of the form `category/package vFROM -> vTO (dev-lang/go …)` using the lane label from `go-tree-lanes`. Split and converge mapping SHALL follow: when one local version maps to multiple new targets, emit one line per target with the same `vFROM`; when multiple locals converge to one target, emit one line per local `vFROM` to that `vTO`. Packages that are fully satisfied for all lanes with targets SHALL NOT produce outdated lines for those lanes.

#### Scenario: Uncollapsed two-lane gap

- **WHEN** local has only `0.80.0` and the plan targets `0.82.0` for `(dev-lang/go amd64)` and `0.84.0` for `(dev-lang/go ~amd64)` (other lanes satisfied or absent)
- **THEN** stdout includes `… v0.80.0 -> v0.82.0 (dev-lang/go amd64)` and `… v0.80.0 -> v0.84.0 (dev-lang/go ~amd64)`

#### Scenario: Converge report shape

- **WHEN** locals are `0.80.0` and `0.82.0` and the plan collapses to a single target `0.84.0` for remaining lanes
- **THEN** stdout includes lines mapping `v0.80.0 -> v0.84.0` and `v0.82.0 -> v0.84.0` with appropriate lane labels

#### Scenario: Fully planned package is silent

- **WHEN** local ebuilds exactly match the planned unique PV set and content fixes are not required
- **THEN** the program writes no outdated stdout line for that package

### Requirement: Non-Go outdated unchanged

Packages that are not `GoVendorAndAssets` SHALL continue to use newest-local vs single fetched latest comparison and the existing single-line `category/package vLOCAL -> vREMOTE` format without Go lane labels.

#### Scenario: Binary package single line

- **WHEN** `dev-util/opencode-bin` local is behind latest remote
- **THEN** stdout has exactly one line for that package without a `(dev-lang/go …)` suffix

## MODIFIED Requirements

### Requirement: Outdated stdout format

For each non-Go package whose local PV is strictly less than the fetched remote PV, the program SHALL write exactly one line to standard output of the form `category/package vLOCAL -> vREMOTE`, where `vLOCAL` and `vREMOTE` are pretty-rendered ebuild versions (leading `v`, optional `-rN` on local when present). For `GoVendorAndAssets` packages, stdout lines SHALL follow the Go tree-lane outdated reporting requirement (possibly multiple lines and lane labels) instead of a single latest-only comparison. Packages that are up to date under their applicable rules SHALL NOT produce a stdout line.

#### Scenario: Package behind upstream

- **WHEN** local newest PV is `2.1.6` and remote is `2.1.10` for a non-Go package that uses latest-only checking
- **THEN** stdout contains the line `category/package v2.1.6 -> v2.1.10` for that package

#### Scenario: Package up to date is silent on stdout

- **WHEN** a package is fully up to date under its applicable outdated rules
- **THEN** the program writes no stdout line for that package
