## MODIFIED Requirements

### Requirement: Outdated stdout format

For each non-Go package whose local PV is strictly less than the fetched remote PV, the program SHALL write exactly one line to standard output of the form `category/package LOCAL -> REMOTE`, where `LOCAL` and `REMOTE` are pretty-rendered ebuild versions in PV form (no leading `v`, optional `-rN` on local when present). For `GoVendorAndAssets` packages, stdout lines SHALL follow the Go tree-lane outdated reporting requirement (possibly multiple lines and lane labels) instead of a single latest-only comparison. Packages that are up to date under their applicable rules SHALL NOT produce a stdout line.

#### Scenario: Package behind upstream

- **WHEN** local newest PV is `2.1.6` and remote is `2.1.10` for a non-Go package that uses latest-only checking
- **THEN** stdout contains the line `category/package 2.1.6 -> 2.1.10` for that package

#### Scenario: Package up to date is silent on stdout

- **WHEN** a package is fully up to date under its applicable outdated rules
- **THEN** the program writes no stdout line for that package

### Requirement: Go tree-lane outdated reporting

For each package whose technique is `GoVendorAndAssets`, the `outdated` check SHALL use the Go tree-lane planner (Gentoo `dev-lang/go` ceilings, upstream candidates, per-lane target PVs) instead of comparing only newest local PV to a single latest remote. For each lane that has a target PV and is not already satisfied by a local non-live ebuild at that PV with adequate content for that tip (ebuild present; content-fix rules for assets URI / BDEPEND matching the PV’s known `go.mod` requirement / KEYWORDS; and Manifest vendor DIST present for that PV’s vendor tarball as defined by `go-vendor-assets`), the program SHALL write a stdout line of the form `category/package FROM -> TO (dev-lang/go …)` using the lane label from `go-tree-lanes`. Split and converge mapping SHALL follow: when one local version maps to multiple new targets, emit one line per target with the same `FROM`; when multiple locals converge to one target, emit one line per local `FROM` to that `TO`. Versions in these lines SHALL be pretty-rendered in PV form (no leading `v`). Packages that are fully satisfied for all lanes with targets SHALL NOT produce outdated lines for those lanes.

Content-fix adequacy for BDEPEND SHALL use the go.mod probe for that planned PV’s tag (shared cache with planning) when available: missing `dev-lang/go` atom or an atom that does not exactly match `>=dev-lang/go-<go.mod version>:=` SHALL count as unsatisfied. Mere presence of any `dev-lang/go` string SHALL NOT count as adequate when the required version is known.

When the reason a present planned PV is still unsatisfied is **only** overlay content or Manifest incompleteness (the local ebuild for that PV already exists) rather than a missing PV ebuild, the program SHALL append the token ` [assets reusable]` to that outdated line so operators can see that apply may complete without re-vendoring if the release asset already exists. Missing planned PV ebuilds SHALL use the normal line without requiring a GitHub probe during `outdated`.

#### Scenario: Uncollapsed two-lane gap

- **WHEN** local has only `0.80.0` and the plan targets `0.82.0` for `(dev-lang/go amd64)` and `0.84.0` for `(dev-lang/go ~amd64)` (other lanes satisfied or absent)
- **THEN** stdout includes `… 0.80.0 -> 0.82.0 (dev-lang/go amd64)` and `… 0.80.0 -> 0.84.0 (dev-lang/go ~amd64)`

#### Scenario: Converge report shape

- **WHEN** locals are `0.80.0` and `0.82.0` and the plan collapses to a single target `0.84.0` for remaining lanes
- **THEN** stdout includes lines mapping `0.80.0 -> 0.84.0` and `0.82.0 -> 0.84.0` with appropriate lane labels

#### Scenario: Fully planned package is silent

- **WHEN** local ebuilds exactly match the planned unique PV set and content and Manifest fixes are not required (including BDEPEND matching known go.mod requirements)
- **THEN** the program writes no outdated stdout line for that package

#### Scenario: Content-fix line marks assets reusable

- **WHEN** planned PV `0.84.0` is present locally with ebuild content that still needs Manifest vendor DIST completion (or other overlay-only content fix) for a lane
- **THEN** the outdated line for that lane includes the substring ` [assets reusable]`

#### Scenario: Wrong BDEPEND is outdated

- **WHEN** planned PV is present with adequate SRC_URI, KEYWORDS, and Manifest vendor DIST, but BDEPEND does not match the probed go.mod requirement for that PV
- **THEN** the program emits an outdated line for the affected lane(s) and does not treat the package as fully up to date

### Requirement: Non-Go outdated unchanged

Packages that are not `GoVendorAndAssets` SHALL continue to use newest-local vs single fetched latest comparison and the single-line `category/package LOCAL -> REMOTE` format (PV form, no leading `v`) without Go lane labels.

#### Scenario: Binary package single line

- **WHEN** `dev-util/opencode-bin` local is behind latest remote
- **THEN** stdout has exactly one line for that package without a `(dev-lang/go …)` suffix

### Requirement: Deferred outdated report emission

When activity indicators were shown for the check phase, the program SHALL emit `outdated` stdout lines and soft-warning log lines only after the check multi-progress panel is cleared. When indicators are disabled, emission timing MAY remain immediate after each report is known or after the batch completes, but stdout format and warning semantics SHALL be unchanged.

#### Scenario: Stdout lines appear after panel clear

- **WHEN** indicators are enabled and at least one package is outdated
- **THEN** the `category/package LOCAL -> REMOTE` lines are written to stdout only after the check progress panel has been cleared
