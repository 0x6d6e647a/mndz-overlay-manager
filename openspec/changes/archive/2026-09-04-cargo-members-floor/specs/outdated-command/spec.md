## MODIFIED Requirements

### Requirement: Go tree-lane outdated reporting

For each package whose technique is `DepsAndAssets`, the `outdated` check SHALL use the runtime-lane planner for that ecosystem (runtime package ceilings, candidate set, per-lane target PVs) instead of comparing only newest local PV to a single latest remote. For each lane that has a target PV and is not satisfied by the canonical highest-revision non-live same-PV ebuild with adequate content for that tip, the program SHALL write a stdout line of the form `category/package FROM -> TO (...)` using the lane label from `runtime-lanes` (for example `(dev-lang/go amd64)`, `(net-libs/nodejs ~amd64)`, `(dev-lang/bun-bin ~arm64)`, or `(dev-lang/rust|rust-bin ~amd64)`). Adequacy SHALL include parameterized asset URI, planned KEYWORDS, the ecosystem runtime comparison, and an exact Manifest `DIST` record for every required primary and companion basename.

Split and converge mapping SHALL follow: when one local version maps to multiple new targets, emit one line per target with the same `FROM`; when multiple locals converge to one target, emit one line per local `FROM` to that `TO`. Versions SHALL use PV pretty form without a leading `v`.

For Cargo, `RUST_MIN_VER` adequacy SHALL use the decision floor from `cargo-crates-assets`: the maximum of the planned tag-floor snapshot and the canonical highest-revision same-PV ebuild's valid `RUST_MIN_VER`. A valid written floor at or above that decision floor SHALL be adequate; a lower, missing, or malformed written floor SHALL need work. If neither decision-floor operand is usable, the PV SHALL be reported as needing work and marked for full-path materialization rather than treated as adequate. Incomplete Cargo tag-floor coverage SHALL NOT be reported as a `0.0.0` requirement; such a candidate SHALL NOT appear as a lane `TO` solely because discovery failed to complete.

A gap line MAY include ` [assets reusable]` only when the PV is not forced full and a release lookup confirms that every required primary and companion asset is usable. If release completeness cannot be established because lookup dependencies are unavailable or lookup fails, `outdated` SHALL still report the needs-work line but SHALL conservatively omit the optional marker. A primary-only or otherwise partial release SHALL NOT receive that marker. The marker rule applies to missing-PV and same-PV content gaps alike.

#### Scenario: Uncollapsed two-lane gap

- **WHEN** local has only `0.80.0` and the plan targets `0.82.0` for `(dev-lang/go amd64)` and `0.84.0` for `(dev-lang/go ~amd64)` with other lanes satisfied or absent
- **THEN** stdout includes both transitions with their corresponding lane labels

#### Scenario: Npm package lane line

- **WHEN** `dev-util/openspec` has a runtime-lane gap for nodejs
- **THEN** stdout includes a labeled line naming the nodejs runtime lane rather than a single unlabeled latest-only comparison

#### Scenario: Bun package lane line

- **WHEN** `dev-util/ralph-tui` has a runtime-lane gap for bun-bin
- **THEN** stdout includes a labeled line naming the bun-bin runtime lane

#### Scenario: Cargo package lane line

- **WHEN** `dev-util/mise` has a runtime-lane gap for the rust toolchain union
- **THEN** stdout includes a labeled line naming `dev-lang/rust|rust-bin` or equivalent rather than remaining soft-skipped as Unsupported

#### Scenario: Cargo ebuild matching the written floor is not flagged

- **WHEN** `dev-util/usage` was written with `RUST_MIN_VER="1.95.0"`, its planned tag floor is `1.91.0`, and its canonical same-PV donor is the same written `1.95.0`
- **WHEN** `outdated` checks the same PV
- **THEN** it does not print a `6.4.1 -> 6.4.1` content-only line

#### Scenario: Highest revision controls outdated adequacy

- **WHEN** bare, `-r2`, and `-r10` ebuilds exist for one planned PV with different content
- **THEN** `outdated` assesses `-r10` regardless of discovery order and ignores a live `9999` ebuild as a donor

#### Scenario: Missing direct Cargo floor is reported as full-path work

- **WHEN** a present Cargo PV has neither a planned tag floor nor a valid floor in its canonical same-PV ebuild
- **THEN** `outdated` reports the lane gap and does not label it `[assets reusable]` even if release assets exist

#### Scenario: Incomplete Cargo candidate is not a zero-floor gap

- **WHEN** the newest upstream Cargo tag is incomplete and an older complete tag remains at or below the rust ceiling
- **THEN** `outdated` does not treat the incomplete newest tag as requirement `0.0.0`

#### Scenario: Missing companion distfile is flagged

- **WHEN** a package's canonical ebuild and primary Manifest record are adequate but an exact Manifest record for a required companion such as opencode models is absent
- **THEN** the package is reported as needing work
- **AND** `[assets reusable]` appears only if every required primary and companion release asset is usable

#### Scenario: Release lookup failure suppresses optional marker

- **WHEN** a needs-work line is known but release completeness lookup fails
- **THEN** `outdated` still emits the line and omits `[assets reusable]` rather than claiming unproven reuse

#### Scenario: Missing PV with complete release may be reusable

- **WHEN** a planned PV is absent locally, is not forced full, and release lookup confirms every required asset
- **THEN** its lane gap may include `[assets reusable]`

#### Scenario: Companion sidecar is not the required distfile

- **WHEN** the only matching-looking Manifest record adds a suffix such as `.asc` to the required companion basename
- **THEN** `outdated` treats the exact companion record as missing
