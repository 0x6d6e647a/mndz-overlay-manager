## MODIFIED Requirements

### Requirement: Outdated stdout format

For each non-`DepsAndAssets` package whose local PV is strictly less than the fetched remote PV, the program SHALL write exactly one line to standard output of the form `category/package LOCAL -> REMOTE`, where `LOCAL` and `REMOTE` are pretty-rendered ebuild versions in PV form (no leading `v`, optional `-rN` on local when present). For `DepsAndAssets` packages, stdout lines SHALL follow the runtime-lane outdated reporting requirement (possibly multiple lines and lane labels) instead of a single latest-only comparison. Packages that are up to date under their applicable rules SHALL NOT produce a stdout line.

#### Scenario: GitMv outdated single line

- **WHEN** a GitMv package is outdated from `1.0` to `1.1`
- **THEN** stdout contains one unlabeled `LOCAL -> REMOTE` line

### Requirement: Go tree-lane outdated reporting

For each package whose technique is `DepsAndAssets`, the `outdated` check SHALL use the runtime-lane planner for that ecosystem (runtime package ceilings, candidate set, per-lane target PVs) instead of comparing only newest local PV to a single latest remote. For each lane that has a target PV and is not already satisfied by a local non-live ebuild at that PV with adequate content for that tip (ebuild present; content-fix rules for assets URI / BDEPEND matching the PV’s known requirement / KEYWORDS; and Manifest distfile DIST present for that PV’s vendor or deps tarball as defined by the ecosystem specs), the program SHALL write a stdout line of the form `category/package FROM -> TO (…)` using the lane label from `runtime-lanes` (e.g. `(dev-lang/go amd64)`, `(net-libs/nodejs ~amd64)`, `(dev-lang/bun-bin ~arm64)`). Split and converge mapping SHALL follow: when one local version maps to multiple new targets, emit one line per target with the same `FROM`; when multiple locals converge to one target, emit one line per local `FROM` to that `TO`. Versions in these lines SHALL use PV pretty form without a leading `v`. When a gap is overlay-only for a PV that already has a reusable release asset, the line MAY include ` [assets reusable]` as specified for Go reuse signaling, generalized to deps distfiles.

#### Scenario: Uncollapsed two-lane gap

- **WHEN** local has only `0.80.0` and the plan targets `0.82.0` for `(dev-lang/go amd64)` and `0.84.0` for `(dev-lang/go ~amd64)` (other lanes satisfied or absent)
- **THEN** stdout includes both transitions with the corresponding lane labels

#### Scenario: Npm package lane line

- **WHEN** `dev-util/openspec` has a runtime-lane gap for nodejs
- **THEN** stdout includes a labeled line naming the nodejs runtime lane rather than a single unlabeled latest-only comparison only

#### Scenario: Bun package lane line

- **WHEN** `dev-util/ralph-tui` has a runtime-lane gap for bun-bin
- **THEN** stdout includes a labeled line naming the bun-bin runtime lane

### Requirement: Non-Go outdated unchanged

Packages that are not `DepsAndAssets` SHALL continue to use newest-local vs single fetched latest comparison and the single-line `category/package LOCAL -> REMOTE` format (PV form, no leading `v`) without runtime-lane labels.

#### Scenario: Binary package format

- **WHEN** `dev-util/opencode-bin` is outdated
- **THEN** stdout uses a single unlabeled line
