## MODIFIED Requirements

### Requirement: MSRV probe and RUST_MIN_VER

For each Cargo candidate or apply PV, the program SHALL determine Cargo floor facts through one planned tag snapshot, one canonical on-disk ebuild rule, and distinct decision, full-build, and reuse-write formulas.

The direct **tag floor** SHALL use an ordered, deduplicated probe of the effective package path (configured package subdirectory, otherwise configured lock subdirectory), configured lock path, and repository root at the candidate tag. At each location, table-aware TOML parsing SHALL consider direct `[package].rust-version` and direct `[workspace.package].rust-version` declarations, in that order. Expected path absence SHALL continue the ordered fallback; transport/auth/server failure, malformed TOML, or a malformed present Rust-version declaration SHALL fail the plan rather than be treated as no declaration. The program SHALL NOT resolve `rust-version.workspace = true` or workspace members in this requirement; a valid inheritance marker contributes no direct floor and probing continues. The selected normalized tag floor, or explicit complete absence, SHALL be retained in the runtime-lane plan and reused by adequacy and apply without another tagged Cargo.toml fetch.

For any bare PV with multiple local ebuild revisions, the authoritative on-disk ebuild SHALL be the highest numeric Gentoo revision among non-live same-PV ebuilds (bare PV before `-r1`, `-r1` before `-r2`, and so on). Live ebuilds SHALL NOT be donors or templates. This authoritative ebuild SHALL supply assessed content and the same-PV donor floor. When no same-PV ebuild exists, the template fallback SHALL be the highest non-live local ebuild from the plan's initial inventory, regardless of whether its PV is below or above the target.

The **decision floor** SHALL be the maximum of the planned direct tag floor and the authoritative same-PV ebuild's valid `RUST_MIN_VER`. A present planned PV SHALL be MSRV-adequate only when it has a valid normalized `RUST_MIN_VER` greater than or equal to that decision floor. A written floor above the decision floor SHALL NOT by itself need a content fix. If neither tag nor authoritative same-PV ebuild supplies a usable floor, the PV SHALL need work and SHALL require full-path materialization; absence SHALL NOT mean adequate.

Cargo candidate runtime-lane selection SHALL use the planned direct tag floor only and SHALL NOT use donor, template, or post-fetch harvest floors. Candidate selection SHALL substitute `"0.0.0"` when the ordered direct tag probe completes successfully with no declaration. That selection-only fallback SHALL NOT be treated as a declared decision/write floor.

The **build floor** for full-path materialization SHALL use a hybrid harvest: the maximum direct Rust-version declarations found (a) by recursively scanning Cargo.toml files under the cloned lock/source tree and (b) in only the package-root Cargo.toml of each registry crate extracted under pack stage `cargo_home/gentoo/{name}-{version}/`. Nested examples or fixtures inside an extracted registry crate SHALL NOT contribute solely because they are below that crate directory. A malformed harvested Cargo.toml or malformed present direct Rust-version declaration SHALL hard-fail the unit; a valid workspace-inheritance marker contributes no direct floor. Harvest SHALL NOT use the `RUST_MIN_VER` field left in pycargoebuild's inplace working ebuild. On a version bump, the build floor SHALL be `max(tag floor, clone harvest, registry harvest)` and SHALL NOT use a previous-PV template floor. On a same-PV rewrite, it SHALL additionally include the authoritative same-PV donor floor.

The **reuse-write floor** SHALL be the maximum of the planned direct tag floor and the valid `RUST_MIN_VER` of the canonical selected template. Reuse SHALL perform no clone or harvest. If neither operand is usable, the unit requires full materialization: it SHALL take the full path when no release tag exists, but an existing release tag SHALL hard-fail the package because automatic release mutation is not supported. A reuse bump MAY preserve a conservative-high floor from another PV indefinitely; the program SHALL NOT be required to schedule a full path solely to lower it.

The program SHALL write the build floor on a full path or the reuse-write floor on a reuse path as exactly one direct `RUST_MIN_VER` assignment, removing duplicate direct assignments from the template. A full-path unit that obtains no tag floor, no clone/registry harvest, and no authoritative same-PV donor SHALL hard-fail before ebuild, Manifest, asset-publication, or commit mutation. Versions SHALL be compared numerically and normalized to three numeric components for comparison and writing (for example `1.91` becomes `1.91.0`, and `1.100` is above `1.99`). The manager SHALL NOT invent a hand-rolled `>=dev-lang/rust-...` BDEPEND line; the rust/cargo eclass owns toolchain dependency expansion.

#### Scenario: Root rust-version present

- **WHEN** the ordered tag probe finds direct `rust-version = "1.88.0"`, no harvest or same-PV donor exceeds it, and the PV is written
- **THEN** the ebuild receives `RUST_MIN_VER="1.88.0"` and subsequent adequacy admits that value

#### Scenario: Missing root rust-version uses max deps and donor

- **WHEN** the direct tag probe finds no declaration, full-path harvest is at most `1.90.0`, and the authoritative same-PV ebuild has `RUST_MIN_VER="1.95.0"`
- **THEN** a same-PV rewrite keeps `RUST_MIN_VER="1.95.0"` and subsequent adequacy admits it

#### Scenario: No MSRV signal hard-fails

- **WHEN** a full-path unit has no planned direct tag floor, no clone or extracted-registry harvest, and no authoritative same-PV donor floor
- **THEN** that unit fails without writing an ebuild, Manifest, published asset, or eclass-default-only minimum

#### Scenario: Missing reuse signal with no release takes full path

- **WHEN** no release tag exists and neither the planned direct tag floor nor the canonical selected template has a usable floor
- **THEN** the unit takes the full path so harvest can determine a floor

#### Scenario: Missing reuse signal conflicts with existing release

- **WHEN** a release tag exists but neither the planned direct tag floor nor the canonical selected template has a usable floor
- **THEN** the package hard-fails before mutation with the conflicting release identity instead of attempting reuse or automatic release replacement

#### Scenario: Bump harvest raises the floor

- **WHEN** a full-path bump has planned direct tag floor `1.91` and an extracted registry package-root manifest declares `rust-version = "1.95"`
- **THEN** the written `RUST_MIN_VER` is `1.95.0` and subsequent decision floors admit it

#### Scenario: Nested registry fixture does not raise the floor

- **WHEN** an extracted registry package root declares `rust-version = "1.91"` but a nested example Cargo.toml declares `1.99`
- **THEN** that nested example alone does not raise the registry harvest above `1.91.0`

#### Scenario: Bump does not carry a stale donor floor

- **WHEN** a package full-path bumps to a new PV, direct tag and harvest floors are `1.91`, and the canonical fallback template from another PV has `RUST_MIN_VER="1.95.0"`
- **THEN** the written `RUST_MIN_VER` is `1.91.0` because the cross-PV template is not a full-path bump operand

#### Scenario: Same-PV rewrite never lowers the authoritative floor

- **WHEN** the highest same-PV revision has `RUST_MIN_VER="1.95.0"` and full-path direct tag and harvest floors are `1.91.0`
- **THEN** the rewrite keeps `RUST_MIN_VER="1.95.0"`

#### Scenario: Highest numeric revision is authoritative

- **WHEN** a package has same-PV bare, `-r2`, and `-r10` ebuilds in arbitrary discovery order
- **THEN** `-r10` supplies assessed content, donor floor, and same-PV template, and a live `9999` ebuild does not participate

#### Scenario: Written floor above the tag probe is adequate

- **WHEN** the authoritative present ebuild has `RUST_MIN_VER="1.95.0"` and the planned direct tag floor is `1.91.0`
- **THEN** content assessment does not report that PV solely because the written floor is not equal to `1.91.0`

#### Scenario: Candidate selection keeps donor out

- **WHEN** a candidate's direct tag floor is `1.91.0` and its authoritative same-PV donor is `1.95.0`
- **THEN** runtime-lane candidate selection uses `1.91.0`, while content adequacy uses decision floor `1.95.0`

#### Scenario: Direct tag absence is distinct from selection fallback

- **WHEN** every ordered tag manifest parses successfully but none has a direct Rust-version declaration
- **THEN** candidate selection may use `0.0.0`, but decision and write logic retain an absent tag floor rather than using `0.0.0` as an ebuild minimum

#### Scenario: Invalid tagged metadata fails closed

- **WHEN** a probed Cargo.toml is malformed or contains a malformed direct Rust-version value
- **THEN** planning fails instead of treating the value as absent or selecting a later fallback as if the manifest were valid

#### Scenario: Workspace inheritance marker remains deferred

- **WHEN** a probed package declares `rust-version.workspace = true` without a direct Rust-version declaration in that manifest
- **THEN** the marker is not treated as malformed or as a direct floor, and the ordered direct probe continues without resolving workspace membership

#### Scenario: Reuse bump may remain conservative-high

- **WHEN** a reuse bump has planned direct tag floor `1.91.0` and its canonical cross-PV fallback template has `RUST_MIN_VER="1.95.0"`
- **THEN** reuse writes `1.95.0`, considers that value adequate, and is not required to schedule a later full path solely to lower it

### Requirement: Cargo reuse path skips pycargoebuild

When a planned Cargo PV needs work, has a derivable reuse-write floor, is not forced full, and an assets release provides every required asset basename including `{pn}-{pv}-crates.tar.xz`, the program SHALL reuse those assets when downloaded bytes pass expected Manifest/trusted-hash verification. Reuse SHALL NOT run pycargoebuild, manager crate packing, or release publication. It MAY rewrite KEYWORDS, `RUST_MIN_VER`, and SRC_URI for plan adequacy, SHALL ensure steady-state tarball shape has empty `CRATES`, then SHALL run `ebuild ... manifest` and verify as for other `DepsAndAssets` ecosystems.

If the release tag exists but any required asset is missing, or if the PV is forced full because no reuse-write floor is derivable, the package SHALL hard-fail before mutation because full publication cannot update, replace, or delete an existing release tag. Absence of the release tag SHALL permit the full path.

#### Scenario: Clean reuse no pycargoebuild

- **WHEN** all required release assets for `usage-3.5.4` exist, their bytes verify, and its reuse-write floor is derivable
- **THEN** apply does not invoke pycargoebuild for that unit

#### Scenario: Clean reuse no manager crate pack

- **WHEN** all required release assets for `usage-3.5.4` exist, their bytes verify, and its reuse-write floor is derivable
- **THEN** apply does not run manager crate packing for that unit

#### Scenario: Reuse clears list-era CRATES

- **WHEN** reuse applies for a PV whose canonical template still has a non-empty `CRATES` list
- **THEN** the written ebuild has empty `CRATES` suitable for crate-tarball packaging

#### Scenario: Existing release cannot satisfy forced-full Cargo unit

- **WHEN** all required assets exist but the Cargo PV is forced full because it has no derivable reuse-write floor
- **THEN** the package hard-fails with release-tag guidance and does not run pycargoebuild or mutate local/remote assets
