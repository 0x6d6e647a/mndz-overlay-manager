## MODIFIED Requirements

### Requirement: Shared materialize spine

For each planned PV that needs work under `DepsAndAssets`, the program SHALL either reuse an existing assets release asset for the expected distfile name or run the ecosystem materializer, publish assets before overlay mutation on the full path, rewrite overlay ebuild content (parameterized assets SRC_URI, planned KEYWORDS, and runtime field from requirement probe — BDEPEND or `RUST_MIN_VER` per ecosystem), run `ebuild … manifest`, verify Manifest SHA512 for the distfile against the published or downloaded bytes, and create the signed overlay commit for that unit before the next PV unit. Host language runtime version gates SHALL apply on the full path only and SHALL NOT apply on the reuse path (Cargo full path does not require host `rustc`).

When multiple planned PVs need work in one package apply, the program SHALL sequence those PV units as specified by `update-apply` multi-lane apply: **missing** PVs (no local non-live ebuild at that PV) before pure **content-fix** units (local ebuild present but inadequate), with stable ascending PV order within each group. Overlay rewrite for a missing PV SHALL read a template from an existing non-live local ebuild when no same-PV file exists; that template path SHALL be validated before read so a missing file yields a unit hard-fail rather than an uncaught filesystem exception.

#### Scenario: Publish before overlay on full path

- **WHEN** the expected release asset is absent and materialization succeeds
- **THEN** assets commit, push, and release upload complete before the overlay ebuild for that PV is renamed or rewritten

#### Scenario: Reuse skips rebuild

- **WHEN** release tag `{pn}-{pv}` already has the expected vendor or deps asset
- **THEN** apply does not rebuild the tarball and does not create a new release for that tag

#### Scenario: Missing PV sequenced before content-fix

- **WHEN** the same package needs both a missing planned PV and a content-fix on a lower local PV in one update
- **THEN** the missing PV unit runs before the content-fix unit that may revision-bump and remove the local donor ebuild path
