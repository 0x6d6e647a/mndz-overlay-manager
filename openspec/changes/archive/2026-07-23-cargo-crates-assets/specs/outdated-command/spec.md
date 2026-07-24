## MODIFIED Requirements

### Requirement: Go tree-lane outdated reporting

For each package whose technique is `DepsAndAssets`, the `outdated` check SHALL use the runtime-lane planner for that ecosystem (runtime package ceilings, candidate set, per-lane target PVs) instead of comparing only newest local PV to a single latest remote. For each lane that has a target PV and is not already satisfied by a local non-live ebuild at that PV with adequate content for that tip (ebuild present; content-fix rules for assets URI / BDEPEND or `RUST_MIN_VER` matching the PV’s known requirement / KEYWORDS; and Manifest distfile DIST present for that PV’s vendor, deps, or crates tarball as defined by the ecosystem specs), the program SHALL write a stdout line of the form `category/package FROM -> TO (…)` using the lane label from `runtime-lanes` (e.g. `(dev-lang/go amd64)`, `(net-libs/nodejs ~amd64)`, `(dev-lang/bun-bin ~arm64)`, `(dev-lang/rust|rust-bin ~amd64)`). Split and converge mapping SHALL follow: when one local version maps to multiple new targets, emit one line per target with the same `FROM`; when multiple locals converge to one target, emit one line per local `FROM` to that `TO`. Versions in these lines SHALL use PV pretty form without a leading `v`. When a gap is overlay-only for a PV that already has a reusable release asset, the line MAY include ` [assets reusable]` as specified for Go reuse signaling, generalized to deps and crates distfiles.

#### Scenario: Uncollapsed two-lane gap

- **WHEN** local has only `0.80.0` and the plan targets `0.82.0` for `(dev-lang/go amd64)` and `0.84.0` for `(dev-lang/go ~amd64)` (other lanes satisfied or absent)
- **THEN** stdout includes both transitions with the corresponding lane labels

#### Scenario: Npm package lane line

- **WHEN** `dev-util/openspec` has a runtime-lane gap for nodejs
- **THEN** stdout includes a labeled line naming the nodejs runtime lane rather than a single unlabeled latest-only comparison only

#### Scenario: Bun package lane line

- **WHEN** `dev-util/ralph-tui` has a runtime-lane gap for bun-bin
- **THEN** stdout includes a labeled line naming the bun-bin runtime lane

#### Scenario: Cargo package lane line

- **WHEN** `dev-util/mise` has a runtime-lane gap for the rust toolchain union
- **THEN** stdout includes a labeled line naming `dev-lang/rust|rust-bin` (or equivalent) rather than remaining soft-skipped as Unsupported
