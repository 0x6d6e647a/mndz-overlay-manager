## MODIFIED Requirements

### Requirement: Cargo ecosystem under DepsAndAssets

The library SHALL support `DepsAndAssets` with ecosystem `Cargo`. Policy MAY supply an optional lock subdirectory (relative to the repository root; `Nothing` means root) where `Cargo.lock` is expected, and an optional package subdirectory for the binary package (`Nothing` means same as lock root). The package subdirectory, when set, is the policy package: tag-floor discovery SHALL start there, and full-path materialize SHALL run `pycargoebuild` with that directory as its argument (workspace members such as usage’s `cli/`). When unset, tag-floor discovery and `pycargoebuild` SHALL start at the lock root. The program SHALL still require `Cargo.lock` at the lock root (Cargo resolves the lockfile by walking parents). Apply SHALL require a `GitHub` update source for Cargo packages and SHALL hard-fail if the source is not GitHub. A virtual workspace root (`[workspace]` without `[package]`) with no package subdirectory SHALL fail planning with an error that names the missing package subdirectory.

#### Scenario: usage package subdir

- **WHEN** policy for `dev-util/usage` uses `DepsAndAssets Cargo` with package subdirectory `cli` and lock at repository root
- **THEN** tag-floor discovery starts at `cli/Cargo.toml` and includes that package’s local path closure
- **AND** `pycargoebuild` runs with the `cli` directory as its directory argument (not the workspace root)

#### Scenario: hk root cargo

- **WHEN** policy for `dev-util/hk` uses `DepsAndAssets Cargo` with no subdirectories
- **THEN** both lock and package metadata are taken from the repository root and `pycargoebuild` runs at the repository root

#### Scenario: Virtual workspace without package subdirectory fails

- **WHEN** a Cargo package’s tagged root has `[workspace]` and no `[package]`, and policy sets no package subdirectory
- **THEN** planning hard-fails without treating the candidate as absent-floor `0.0.0`

### Requirement: MSRV probe and RUST_MIN_VER

For each Cargo candidate or apply PV, the program SHALL determine Cargo floor facts through one planned tag snapshot, one canonical on-disk ebuild rule, and distinct decision, full-build, and reuse-write formulas.

The **tag floor** `T(pv)` SHALL be the numeric maximum effective `rust-version` over the **active** local package set at the candidate tag:

1. The policy package is the configured package subdirectory, otherwise the configured lock subdirectory, otherwise the repository root.
2. Effective rust-version for a package is a direct `[package].rust-version` if present, else a resolved `rust-version.workspace = true` against that package’s workspace document. The workspace document is the relative path in `package.workspace` when present, otherwise the lock-root then repository-root `Cargo.toml` `[workspace.package]` table. Direct `[package].rust-version` in the same file SHALL win over `[workspace.package].rust-version`.
3. The active set is the policy package plus local path dependencies enabled by the default emerge compile: listed `features` on the dependency line unioned with the dependency’s `default` features, honoring `default-features = false`, following `dep:` optional path deps those features enable. A feature token `name/feature` SHALL enable feature `feature` on path dependency `name` and SHALL enable optional `name` when that token is active. A weak token `name?/feature` SHALL NOT enable optional `name` by itself; if `name` is already enabled, it SHALL request `feature` on that dependency. The walk SHALL include `[dependencies]`, `[build-dependencies]`, and `[target]` tables that are not windows-only or wasm-only. The walk SHALL exclude `[dev-dependencies]`. `foo = { workspace = true }` SHALL resolve path and features from `[workspace.dependencies]`.
4. Target tables that match Linux, including `cfg(unix)`, Linux triples, and `cfg(not(windows))`, SHALL be active. Target tables that can match only windows or wasm SHALL be ignored. Target tables that match only macOS or BSD SHALL be **watched**: they are walked for comparison and SHALL NOT contribute to `T(pv)` or clone harvest. If the max watched rust-version is strictly greater than the active max (absent active floor is less than a present watched floor), planning SHALL hard-fail and name the watched path, its floor, and the active floor.
5. A path that normalizes outside the tagged repository tree SHALL hard-fail the plan and name the path. An in-tree path dependency whose `Cargo.toml` is missing SHALL make the candidate **incomplete**. Unreadable feature, `dep:`, or `cfg` syntax SHALL make the candidate incomplete. `name/feature` and weak `name?/feature` SHALL NOT be treated as unreadable. Weak `dep:name?` SHALL be unreadable. An unknown workspace document for a needed inheritance marker SHALL make the candidate incomplete. Malformed TOML, a malformed present rust-version, transport/auth/server failure, and other fetch errors SHALL fail the plan. Cycles SHALL be visited once. `[patch]` path entries inside the tree SHALL be followed; a patch path that escapes the tree SHALL hard-fail.
6. `workspace.members` globs and `default-members` SHALL NOT define `T(pv)`. A glob SHALL NOT be treated as an empty member list.

Complete discovery with no declared rust-version anywhere in the active set is explicit tag-floor **absence**. Candidate selection MAY substitute `"0.0.0"` only for that complete absence. Incomplete coverage SHALL NOT be treated as absence or as `"0.0.0"`: the candidate is not a parseable runtime requirement. The selected normalized tag floor, or explicit complete absence, plus completeness, reasons, and resolved-path provenance SHALL be retained in the runtime-lane plan and reused by adequacy and apply without another tagged Cargo.toml fetch.

For any bare PV with multiple local ebuild revisions, the authoritative on-disk ebuild SHALL be the highest numeric Gentoo revision among non-live same-PV ebuilds (bare PV before `-r1`, `-r1` before `-r2`, and so on). Live ebuilds SHALL NOT be donors or templates. This authoritative ebuild SHALL supply assessed content and the same-PV donor floor. When no same-PV ebuild exists, the template fallback SHALL be the highest non-live local ebuild from the plan's initial inventory, regardless of whether its PV is below or above the target.

The **decision floor** SHALL be the maximum of the planned tag floor and the authoritative same-PV ebuild's valid `RUST_MIN_VER`. A present planned PV SHALL be MSRV-adequate only when it has a valid normalized `RUST_MIN_VER` greater than or equal to that decision floor. A written floor above the decision floor SHALL NOT by itself need a content fix. If neither tag nor authoritative same-PV ebuild supplies a usable floor, the PV SHALL need work and SHALL require full-path materialization; absence SHALL NOT mean adequate.

Cargo candidate runtime-lane selection SHALL use the planned tag floor only and SHALL NOT use donor, template, or post-fetch harvest floors. Candidate selection SHALL substitute `"0.0.0"` only when active-set discovery completes with no declaration. That selection-only fallback SHALL NOT be treated as a declared decision/write floor.

The **build floor** for full-path materialization SHALL use a hybrid harvest: the maximum effective rust-version found (a) by walking the same active local package set under the cloned lock/source tree as used for `T(pv)` and (b) in only the package-root Cargo.toml of each registry crate extracted under pack stage `cargo_home/gentoo/{name}-{version}/`. Clone harvest SHALL NOT raise the floor from workspace members, benches, xtask, fixtures, or other tree manifests that are not in the active set. Nested examples or fixtures inside an extracted registry crate SHALL NOT contribute solely because they are below that crate directory. A malformed harvested Cargo.toml or malformed present rust-version declaration SHALL hard-fail the unit. Harvest SHALL resolve `rust-version.workspace = true` the same way as tag discovery. Harvest SHALL NOT use the `RUST_MIN_VER` field left in pycargoebuild's inplace working ebuild. On a version bump, the build floor SHALL be `max(tag floor, clone harvest, registry harvest)` and SHALL NOT use a previous-PV template floor. On a same-PV rewrite, it SHALL additionally include the authoritative same-PV donor floor.

After clone harvest and registry harvest are known, if `max(clone harvest, registry harvest)` is strictly greater than the rust ceiling of the lane that selected the PV, the unit SHALL hard-fail before ebuild, Manifest, asset-publication, or commit mutation. The error SHALL name the planned tag floor, the harvest floor, the lane ceiling, and the PV. The program SHALL NOT switch the planned reuse/full route to recover.

The **reuse-write floor** SHALL be the maximum of the planned tag floor and the valid `RUST_MIN_VER` of the canonical selected template. Reuse SHALL perform no clone or harvest. Incomplete tag coverage SHALL NOT produce a reuse-write floor from `"0.0.0"`. If neither operand is usable, the unit requires full materialization: it SHALL take the full path when no release tag exists, but an existing release tag SHALL hard-fail the package because automatic release mutation is not supported. A reuse bump MAY preserve a conservative-high floor from another PV indefinitely; the program SHALL NOT be required to schedule a full path solely to lower it.

The program SHALL write the build floor on a full path or the reuse-write floor on a reuse path as exactly one direct `RUST_MIN_VER` assignment, removing duplicate direct assignments from the template. A full-path unit that obtains no tag floor, no clone/registry harvest, and no authoritative same-PV donor SHALL hard-fail before ebuild, Manifest, asset-publication, or commit mutation. Versions SHALL be compared numerically and normalized to three numeric components for comparison and writing (for example `1.91` becomes `1.91.0`, and `1.100` is above `1.99`). The manager SHALL NOT invent a hand-rolled `>=dev-lang/rust-...` BDEPEND line; the rust/cargo eclass owns toolchain dependency expansion.

#### Scenario: Root rust-version present

- **WHEN** the policy package declares direct `rust-version = "1.88.0"`, no harvest or same-PV donor exceeds it, and the PV is written
- **THEN** the ebuild receives `RUST_MIN_VER="1.88.0"` and subsequent adequacy admits that value

#### Scenario: Missing root rust-version uses max deps and donor

- **WHEN** the active tag set has no declaration, full-path harvest is at most `1.90.0`, and the authoritative same-PV ebuild has `RUST_MIN_VER="1.95.0"`
- **THEN** a same-PV rewrite keeps `RUST_MIN_VER="1.95.0"` and subsequent adequacy admits it

#### Scenario: No MSRV signal hard-fails

- **WHEN** a full-path unit has no planned tag floor, no clone or extracted-registry harvest, and no authoritative same-PV donor floor
- **THEN** that unit fails without writing an ebuild, Manifest, published asset, or eclass-default-only minimum

#### Scenario: Missing reuse signal with no release takes full path

- **WHEN** no release tag exists and neither the planned tag floor nor the canonical selected template has a usable floor
- **THEN** the unit takes the full path so harvest can determine a floor

#### Scenario: Missing reuse signal conflicts with existing release

- **WHEN** a release tag exists but neither the planned tag floor nor the canonical selected template has a usable floor
- **THEN** the package hard-fails before mutation with the conflicting release identity instead of attempting reuse or automatic release replacement

#### Scenario: Bump harvest raises the floor

- **WHEN** a full-path bump has planned tag floor `1.91` and an extracted registry package-root manifest declares `rust-version = "1.95"`
- **THEN** the written `RUST_MIN_VER` is `1.95.0` and subsequent decision floors admit it

#### Scenario: Nested registry fixture does not raise the floor

- **WHEN** an extracted registry package root declares `rust-version = "1.91"` but a nested example Cargo.toml declares `1.99`
- **THEN** that nested example alone does not raise the registry harvest above `1.91.0`

#### Scenario: Bump does not carry a stale donor floor

- **WHEN** a package full-path bumps to a new PV, tag and harvest floors are `1.91`, and the canonical fallback template from another PV has `RUST_MIN_VER="1.95.0"`
- **THEN** the written `RUST_MIN_VER` is `1.91.0` because the cross-PV template is not a full-path bump operand

#### Scenario: Same-PV rewrite never lowers the authoritative floor

- **WHEN** the highest same-PV revision has `RUST_MIN_VER="1.95.0"` and full-path tag and harvest floors are `1.91.0`
- **THEN** the rewrite keeps `RUST_MIN_VER="1.95.0"`

#### Scenario: Highest numeric revision is authoritative

- **WHEN** a package has same-PV bare, `-r2`, and `-r10` ebuilds in arbitrary discovery order
- **THEN** `-r10` supplies assessed content, donor floor, and same-PV template, and a live `9999` ebuild does not participate

#### Scenario: Written floor above the tag probe is adequate

- **WHEN** the authoritative present ebuild has `RUST_MIN_VER="1.95.0"` and the planned tag floor is `1.91.0`
- **THEN** content assessment does not report that PV solely because the written floor is not equal to `1.91.0`

#### Scenario: Candidate selection keeps donor out

- **WHEN** a candidate's tag floor is `1.91.0` and its authoritative same-PV donor is `1.95.0`
- **THEN** runtime-lane candidate selection uses `1.91.0`, while content adequacy uses decision floor `1.95.0`

#### Scenario: Direct tag absence is distinct from selection fallback

- **WHEN** every active-set manifest at the tag parses successfully but none has a declared rust-version
- **THEN** candidate selection may use `0.0.0`, but decision and write logic retain an absent tag floor rather than using `0.0.0` as an ebuild minimum

#### Scenario: Invalid tagged metadata fails closed

- **WHEN** a needed Cargo.toml is malformed or contains a malformed present rust-version value
- **THEN** planning fails instead of treating the value as absent or selecting a later fallback as if the manifest were valid

#### Scenario: Workspace inheritance marker remains deferred

- **WHEN** a probed package declares `rust-version.workspace = true` without a direct Rust-version declaration in that manifest
- **THEN** the marker is not treated as malformed or as a direct floor in that file
- **AND** the effective floor is taken from the workspace document when that document is known
- **AND** the candidate is incomplete when the workspace document cannot be identified

#### Scenario: Workspace inheritance marker resolves

- **WHEN** the policy package declares `rust-version.workspace = true` and the workspace document has `[workspace.package] rust-version = "1.91"`
- **THEN** the planned tag floor is `1.91.0`

#### Scenario: Reuse bump may remain conservative-high

- **WHEN** a reuse bump has planned tag floor `1.91.0` and its canonical cross-PV fallback template has `RUST_MIN_VER="1.95.0"`
- **THEN** reuse writes `1.95.0`, considers that value adequate, and is not required to schedule a later full path solely to lower it

#### Scenario: Path closure excludes unrelated workspace members

- **WHEN** `dev-util/usage` policy starts at `cli/`, `cli` path-depends on crates that declare `1.91`, and `benches/shadows/mise` or `xtask` declare `1.99` or omit rust-version
- **THEN** the planned tag floor and clone harvest are `1.91.0` and are not raised by those unrelated members

#### Scenario: Default-enabled optional path dep is included

- **WHEN** the policy package enables a feature that turns on an optional local `dep:` path crate declaring `1.92`, and the policy package itself declares `1.91`
- **THEN** the planned tag floor is `1.92.0`

#### Scenario: Namespaced dep/feature tokens are readable

- **WHEN** the policy package default features include `vfox/vendored-lua` and `vfox` is a local path crate, or a path crate’s features table lists `usage-argv/spec`
- **THEN** that candidate is complete rather than incomplete for unreadable feature syntax
- **AND** `vfox/vendored-lua` requests feature `vendored-lua` on the `vfox` path crate

#### Scenario: Weak namespaced feature does not enable an optional path crate

- **WHEN** a path crate’s enabled features include only `usage-test?/completions` and `usage-test` is an optional local path crate declaring a higher rust-version
- **THEN** that optional crate alone does not raise the planned tag floor

#### Scenario: Dev-dependency path crate is excluded

- **WHEN** a local path crate appears only under `[dev-dependencies]` and declares a higher rust-version than the policy package
- **THEN** that crate alone does not raise the planned tag floor

#### Scenario: Incomplete coverage is not a zero floor

- **WHEN** an in-tree path dependency listed by the policy package has no Cargo.toml at the tag
- **THEN** that candidate is not selected for any rust lane and is not treated as requirement `0.0.0`

#### Scenario: Escaping path hard-fails

- **WHEN** a path dependency or `package.workspace` normalizes above the tagged repository root
- **THEN** planning hard-fails and the error names that path

#### Scenario: Watched macos-only crate that would raise T hard-fails

- **WHEN** the Linux-active set’s max rust-version is `1.91` and a macos-only target-table path crate declares `1.95`
- **THEN** planning hard-fails and the error names the watched path, `1.95.0`, and the active floor

#### Scenario: Watched macos-only crate at the same floor does not fail

- **WHEN** the Linux-active set’s max rust-version is `1.91` and a macos-only target-table path crate also declares `1.91`
- **THEN** planning succeeds with tag floor `1.91.0` and clone harvest does not depend on that macos-only crate

#### Scenario: Windows-only target table is ignored

- **WHEN** a path crate is reachable only through a windows-only target table and declares `1.99`
- **THEN** that crate does not raise `T(pv)` and does not hard-fail as a watched raise

#### Scenario: Harvest above the selected lane ceiling hard-fails before write

- **WHEN** a full-path Cargo PV was selected under rust ceiling `1.92` with planned tag floor `1.91` and registry harvest is `1.95`
- **THEN** the unit fails before overlay ebuild, Manifest, asset publication, or commit
- **AND** the error names the tag floor, harvest floor, lane ceiling, and PV
