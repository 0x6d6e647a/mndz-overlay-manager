## Purpose

Cargo ecosystem under `DepsAndAssets`: pycargoebuild crate-tarball materialize, manager-owned crates tarball pack, distfile naming, MSRV probe (including `rust-toolchain.toml` dotted channel), SRC_URI/`RUST_MIN_VER` ownership, rusty_v8 submodule sidecar, policy for hk/mise/usage/biodiff/codex, preflight tools, and reuse vs full path.

## Requirements

### Requirement: Cargo ecosystem under DepsAndAssets

The library SHALL support `DepsAndAssets` with ecosystem `Cargo`. Policy SHALL declare a Cargo provenance: `CargoGitTag` or `CargoCratesIo`. Policy MAY supply an optional lock subdirectory (relative to the repository root; `Nothing` means root) where `Cargo.lock` is expected, and an optional package subdirectory for the binary package (`Nothing` means same as lock root). The package subdirectory, when set, is the policy package: tag-floor discovery SHALL start there, and full-path materialize SHALL run `pycargoebuild` with that directory as its argument (workspace members such as usage’s `cli/`). When unset, tag-floor discovery and `pycargoebuild` SHALL start at the lock root. The program SHALL still require `Cargo.lock` at the lock root (Cargo resolves the lockfile by walking parents). Apply SHALL require a `GitHub` update source for provenance `CargoGitTag` Cargo packages and SHALL hard-fail if the source is not GitHub; provenance `CargoCratesIo` packages MAY use a `GitHub` update source for version detection and tag-floor probing while materialization uses the published crates.io crate. A virtual workspace root (`[workspace]` without `[package]`) with no package subdirectory SHALL fail planning with an error that names the missing package subdirectory.

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

#### Scenario: biodiff crates.io provenance

- **WHEN** policy for `dev-util/biodiff` uses `DepsAndAssets Cargo` with provenance `CargoCratesIo` and source GitHub `8051enthusiast`/`biodiff` with tag prefix `v`
- **THEN** version detection and tag-floor probing use that GitHub source
- **AND** full-path materialize uses the published crates.io crate for the target PV, not the git tag

### Requirement: pycargoebuild crate-tarball materialize

For `DepsAndAssets Cargo` with provenance `CargoGitTag`, full-path materialization of PV, the program SHALL: (1) clone the package’s GitHub source into the unit `work/` directory under the product temporary workspace defined by `temp-workspace` and check out the tag formed by the source tag prefix plus that PV; (2) run `pycargoebuild` with crate-tarball mode against the package subdirectory when policy sets one, otherwise against the lock root, inplace-updating the working ebuild, without invoking `pkgdev manifest` (`-M`), with `--no-write-crate-tarball` so pycargoebuild does not create the crates archive, passing a manager-chosen `--crate-tarball-path` whose basename is `{pn}-{pv}-crates.tar.xz` and `--crate-tarball-prefix` `cargo_home/gentoo`, using a temporary distdir under the unit work area for fetched crates; (3) after pycargoebuild succeeds, pack the fetched registry crates into that tarball path under the unit `out/` as specified by the manager-owned crates tarball pack requirement; (4) not reimplement pycargoebuild’s crate fetch or license logic in Haskell. The program MAY parse `Cargo.lock` for packing and for MSRV. The temporary clone, temp distdir, and pack stage tree SHALL follow the `temp-workspace` unit lifecycle (delete the unit tree on success or soft-skip; retain on hard-fail with path in the error). Full-path clone, `pycargoebuild`, fetch, and pack SHALL run in the materialize container. The program SHALL NOT require host `rustc`, `cargo`, `pycargoebuild`, or `xz` for packing.

#### Scenario: Full path invokes pycargoebuild

- **WHEN** full-path materialize runs for `mise` at PV `2026.7.5`
- **THEN** the process runs `pycargoebuild` with `--crate-tarball`, `--no-write-crate-tarball`, and a tarball path whose basename is `mise-2026.7.5-crates.tar.xz`

#### Scenario: Full path pack produces the crates tarball

- **WHEN** full-path materialize runs for `mise` at PV `2026.7.5` and pycargoebuild succeeds
- **THEN** the manager writes `mise-2026.7.5-crates.tar.xz` at the planned path and does not rely on pycargoebuild to create that file

#### Scenario: No host rustc gate

- **WHEN** full-path cargo materialize runs without `rustc` on the host PATH
- **THEN** packing is not failed solely due to missing host `rustc`

### Requirement: Cargo distfile and release naming

For Cargo packages, the program SHALL name the dependency distfile `{pn}-{pv}-crates.tar.xz` using the overlay package name PN and version PV without revision. Release tags SHALL remain `{pn}-{pv}`. The program SHALL pass this basename to pycargoebuild via `--crate-tarball-path` (for tarball mode / empty CRATES metadata) and SHALL write that same basename when packing after pycargoebuild, rather than relying on Cargo.toml package name defaults when they could differ from PN.

#### Scenario: mise crates name

- **WHEN** publishing assets for package `mise` at PV `2026.7.5`
- **THEN** the distfile basename is `mise-2026.7.5-crates.tar.xz` and the release tag is `mise-2026.7.5`

### Requirement: MSRV probe and RUST_MIN_VER

For each Cargo candidate or apply PV, the program SHALL determine Cargo floor facts through one planned tag snapshot, one canonical on-disk ebuild rule, and distinct decision, full-build, and reuse-write formulas.

The **tag floor** `T(pv)` SHALL be the numeric maximum effective `rust-version` over the **active** local package set at the candidate tag:

1. The policy package is the configured package subdirectory, otherwise the configured lock subdirectory, otherwise the repository root.
2. Effective rust-version for a package is a direct `[package].rust-version` if present, else a resolved `rust-version.workspace = true` against that package’s workspace document. The workspace document is the relative path in `package.workspace` when present, otherwise the lock-root then repository-root `Cargo.toml` `[workspace.package]` table. Direct `[package].rust-version` in the same file SHALL win over `[workspace.package].rust-version`.
3. The active set is the policy package plus local path dependencies enabled by the default emerge compile: listed `features` on the dependency line unioned with the dependency’s `default` features, honoring `default-features = false`, following `dep:` optional path deps those features enable. A feature token `name/feature` SHALL enable feature `feature` on path dependency `name` and SHALL enable optional `name` when that token is active. A weak token `name?/feature` SHALL NOT enable optional `name` by itself; if `name` is already enabled, it SHALL request `feature` on that dependency. The walk SHALL include `[dependencies]`, `[build-dependencies]`, and `[target]` tables that are not windows-only or wasm-only. The walk SHALL exclude `[dev-dependencies]`. `foo = { workspace = true }` SHALL resolve path and features from `[workspace.dependencies]`.
4. Target tables that match Linux, including `cfg(unix)`, Linux triples, and `cfg(not(windows))`, SHALL be active. Target tables that can match only windows or wasm SHALL be ignored. Target tables that match only macOS or BSD SHALL be **watched**: they are walked for comparison and SHALL NOT contribute to `T(pv)` or source harvest. If the max watched rust-version is strictly greater than the active max (absent active floor is less than a present watched floor), planning SHALL hard-fail and name the watched path, its floor, and the active floor.
5. A path that normalizes outside the tagged repository tree SHALL hard-fail the plan and name the path. An in-tree path dependency whose `Cargo.toml` is missing SHALL make the candidate **incomplete**. Unreadable feature, `dep:`, or `cfg` syntax SHALL make the candidate incomplete. `name/feature` and weak `name?/feature` SHALL NOT be treated as unreadable. Weak `dep:name?` SHALL be unreadable. An unknown workspace document for a needed inheritance marker SHALL make the candidate incomplete. Malformed TOML, a malformed present rust-version, transport/auth/server failure, and other fetch errors SHALL fail the plan. Cycles SHALL be visited once. `[patch]` path entries inside the tree SHALL be followed; a patch path that escapes the tree SHALL hard-fail.
6. `workspace.members` globs and `default-members` SHALL NOT define `T(pv)`. A glob SHALL NOT be treated as an empty member list.

Complete discovery with no declared rust-version anywhere in the active set is explicit tag-floor **absence**, except that a dotted `rust-toolchain.toml` channel MAY supply `T(pv)` as specified by the rust-toolchain.toml dotted channel as tag floor requirement. Candidate selection MAY substitute `"0.0.0"` only for that complete absence. Incomplete coverage SHALL NOT be treated as absence or as `"0.0.0"`: the candidate is not a parseable runtime requirement. The selected normalized tag floor, or explicit complete absence, plus completeness, reasons, and resolved-path provenance SHALL be retained in the runtime-lane plan and reused by adequacy and apply without another tagged Cargo.toml fetch.

For any bare PV with multiple local ebuild revisions, the authoritative on-disk ebuild SHALL be the highest numeric Gentoo revision among non-live same-PV ebuilds (bare PV before `-r1`, `-r1` before `-r2`, and so on). Live ebuilds SHALL NOT be donors or templates. This authoritative ebuild SHALL supply assessed content and the same-PV donor floor. When no same-PV ebuild exists, the template fallback SHALL be the highest non-live local ebuild from the plan's initial inventory, regardless of whether its PV is below or above the target.

The **decision floor** SHALL be the maximum of the planned tag floor and the authoritative same-PV ebuild's valid `RUST_MIN_VER`. A present planned PV SHALL be MSRV-adequate only when it has a valid normalized `RUST_MIN_VER` greater than or equal to that decision floor. A written floor above the decision floor SHALL NOT by itself need a content fix. If neither tag nor authoritative same-PV ebuild supplies a usable floor, the PV SHALL need work and SHALL require full-path materialization; absence SHALL NOT mean adequate.

Cargo candidate runtime-lane selection SHALL use the planned tag floor only and SHALL NOT use donor, template, or post-fetch harvest floors. Candidate selection SHALL substitute `"0.0.0"` only when active-set discovery completes with no declaration. That selection-only fallback SHALL NOT be treated as a declared decision/write floor.

The **build floor** for full-path materialization SHALL use a hybrid harvest: the maximum effective rust-version found (a) by walking the active local package set under the provenance source tree — provenance `CargoGitTag`: the cloned tree as used for `T(pv)`; provenance `CargoCratesIo`: the unpacked published crate, whose manifest declares no in-tree path dependencies — and (b) in only the package-root Cargo.toml of each registry crate extracted under pack stage `cargo_home/gentoo/{name}-{version}/`. The source-tree harvest SHALL NOT raise the floor from workspace members, benches, xtask, fixtures, or other tree manifests that are not in the active set. Nested examples or fixtures inside an extracted registry crate SHALL NOT contribute solely because they are below that crate directory. A malformed harvested Cargo.toml or malformed present rust-version declaration SHALL hard-fail the unit. Harvest SHALL resolve `rust-version.workspace = true` the same way as tag discovery. Harvest SHALL NOT use the `RUST_MIN_VER` field left in pycargoebuild's inplace working ebuild. On a version bump, the build floor SHALL be `max(tag floor, source harvest, registry harvest)` and SHALL NOT use a previous-PV template floor. On a same-PV rewrite, it SHALL additionally include the authoritative same-PV donor floor.

After source harvest and registry harvest are known, if `max(source harvest, registry harvest)` is strictly greater than the rust ceiling of the lane that selected the PV, the unit SHALL hard-fail before ebuild, Manifest, asset-publication, or commit mutation. The error SHALL name the planned tag floor, the harvest floor, the lane ceiling, and the PV. The program SHALL NOT switch the planned reuse/full route to recover.

The **reuse-write floor** SHALL be the maximum of the planned tag floor and the valid `RUST_MIN_VER` of the canonical selected template. Reuse SHALL perform no clone, crate download, or harvest. Incomplete tag coverage SHALL NOT produce a reuse-write floor from `"0.0.0"`. If neither operand is usable, the unit requires full materialization: it SHALL take the full path when no release tag exists, but an existing release tag SHALL hard-fail the package because automatic release mutation is not supported. A reuse bump MAY preserve a conservative-high floor from another PV indefinitely; the program SHALL NOT be required to schedule a full path solely to lower it.

The program SHALL write the build floor on a full path or the reuse-write floor on a reuse path as exactly one direct `RUST_MIN_VER` assignment, removing duplicate direct assignments from the template. A full-path unit that obtains no tag floor, no source/registry harvest, and no authoritative same-PV donor SHALL hard-fail before ebuild, Manifest, asset-publication, or commit mutation. Versions SHALL be compared numerically and normalized to three numeric components for comparison and writing (for example `1.91` becomes `1.91.0`, and `1.100` is above `1.99`). The manager SHALL NOT invent a hand-rolled `>=dev-lang/rust-...` BDEPEND line; the rust/cargo eclass owns toolchain dependency expansion.

#### Scenario: Root rust-version present

- **WHEN** the policy package declares direct `rust-version = "1.88.0"`, no harvest or same-PV donor exceeds it, and the PV is written
- **THEN** the ebuild receives `RUST_MIN_VER="1.88.0"` and subsequent adequacy admits that value

#### Scenario: Missing root rust-version uses max deps and donor

- **WHEN** the active tag set has no declaration, full-path harvest is at most `1.90.0`, and the authoritative same-PV ebuild has `RUST_MIN_VER="1.95.0"`
- **THEN** a same-PV rewrite keeps `RUST_MIN_VER="1.95.0"` and subsequent adequacy admits it

#### Scenario: No MSRV signal hard-fails

- **WHEN** a full-path unit has no planned tag floor, no source or extracted-registry harvest, and no authoritative same-PV donor floor
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
- **THEN** the planned tag floor and source harvest are `1.91.0` and are not raised by those unrelated members

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
- **THEN** planning succeeds with tag floor `1.91.0` and source harvest does not depend on that macos-only crate

#### Scenario: Windows-only target table is ignored

- **WHEN** a path crate is reachable only through a windows-only target table and declares `1.99`
- **THEN** that crate does not raise `T(pv)` and does not hard-fail as a watched raise

#### Scenario: Harvest above the selected lane ceiling hard-fails before write

- **WHEN** a full-path Cargo PV was selected under rust ceiling `1.92` with planned tag floor `1.91` and registry harvest is `1.95`
- **THEN** the unit fails before overlay ebuild, Manifest, asset publication, or commit
- **AND** the error names the tag floor, harvest floor, lane ceiling, and PV

#### Scenario: CratesIo source harvest walks the unpacked crate

- **WHEN** a `CargoCratesIo` full-path unit has an unpacked published crate whose active manifests declare no rust-version, and an extracted registry crate under pack stage `cargo_home/gentoo/` declares `rust-version = "1.80"`
- **THEN** the written `RUST_MIN_VER` is `1.80.0`

### Requirement: rust-toolchain.toml dotted channel as tag floor

When active-set discovery for a Cargo candidate completes with no `rust-version` declaration, the program SHALL read `rust-toolchain.toml` at the lock root (else the repository root). If that file’s `channel` is a dotted numeric version (optional leading `v`), `T(pv)` SHALL be that normalized three-component version and SHALL take precedence over substituting `"0.0.0"` for rust-version absence. Channel values that are not dotted versions (`stable`, `nightly`, date nightlies, or malformed) SHALL NOT supply a tag floor. Complete absence of both a rust-version and a dotted channel remains explicit tag-floor absence. A malformed `rust-toolchain.toml` that cannot be parsed SHALL fail the plan.

#### Scenario: Codex channel becomes T(pv)

- **WHEN** the active set at tag `rust-v0.153.3` declares no `rust-version` and `codex-rs/rust-toolchain.toml` has `channel = "1.95.0"`
- **THEN** planned tag floor `T(pv)` is `1.95.0`
- **AND** candidate selection does not use `0.0.0` for that PV

#### Scenario: stable channel does not invent a floor

- **WHEN** the active set has no `rust-version` and `rust-toolchain.toml` has `channel = "stable"`
- **THEN** that file does not supply `T(pv)`
- **AND** complete absence rules still apply

### Requirement: rusty_v8 submodule sidecar

When full-path Cargo materialize of a GitTag package’s lock pins a crates.io `v8` package, the program SHALL treat a rusty_v8+recursive-submodules snapshot as a required companion asset keyed by that crate version, not by overlay PV. Full-path SHALL: (1) parse the `v8` name/version/checksum from the provenance lock; (2) if mndz-overlay-assets already has `rusty-v8-${ver}-with-submodules.tar.xz` (or the agreed basename) for that version and bytes verify, reuse it without cloning; (3) otherwise clone `https://github.com/denoland/rusty_v8` at tag `v${ver}` with recursive submodules inside the materialize container, pack under the hermetic tar/xz rules, and publish a new assets release keyed by crate version. The program SHALL NOT pack this tree into `{pn}-{pv}-crates.tar.xz`. The program SHALL NOT key the snapshot on Codex PV. Chromium clang and rust-toolchain GCS objects SHALL remain ebuild `SRC_URI` distfiles, not overlay-assets.

A GitTag package whose lock does not pin crates.io `v8` SHALL NOT grow this sidecar.

#### Scenario: Same v8 pin reuses the snapshot

- **WHEN** full-path materialize runs for `codex` 0.153.4 and the lock still pins `v8` `150.4.0` and assets already hold `rusty-v8-150.4.0-with-submodules.tar.xz`
- **THEN** apply does not clone `denoland/rusty_v8`
- **AND** it still publishes `{pn}-0.153.4-crates.tar.xz` as a new crates sidecar

#### Scenario: Pin change harvests a new snapshot

- **WHEN** full-path materialize runs for a Cargo GitTag PV whose lock pins `v8` `150.5.0` and no rusty_v8 snapshot exists for `150.5.0`
- **THEN** the container clones tag `v150.5.0` with recursive submodules
- **AND** it publishes `rusty-v8-150.5.0-with-submodules.tar.xz`

#### Scenario: hk is unaffected

- **WHEN** full-path materialize runs for `dev-util/hk`
- **THEN** apply does not harvest or require a rusty_v8 snapshot solely because hk is Cargo GitTag

### Requirement: Windows-only git remotes omitted from GIT_CRATES

When writing or repairing `GIT_CRATES` for a Cargo GitTag ebuild, the program SHALL omit git packages that the lock records only as dependencies of `[target.'cfg(windows)'.dependencies]` (or equivalent windows-only target tables) of the active Linux set. `microsoft/mxc` / `appcontainer_common` for Codex SHALL be omitted.

#### Scenario: mxc dumped

- **WHEN** the manager writes `GIT_CRATES` for `dev-util/codex`
- **THEN** the map has no `microsoft/mxc` entry
- **AND** Linux git remotes such as `crossterm` remain

### Requirement: Manager-owned SRC_URI for cargo

After pycargoebuild inplace update on full path (or on content repair), the program SHALL rewrite the ebuild `SRC_URI` to the provenance-appropriate primary source line plus the mndz-overlay-assets crates tarball URL for `{pn}-${PV}-crates.tar.xz`, and SHALL NOT rely on `${CARGO_CRATE_URIS}` as the **registry** dependency distfile source for steady-state tarball-shaped ebuilds. Provenance `CargoGitTag`: the primary source line is the upstream GitHub source archive for the tag. Provenance `CargoCratesIo`: the primary source line is the canonical crates.io download distfile for the policy crate name and PV, `https://crates.io/api/v1/crates/<crate>/<pv>/download -> <p>.crate`.

The program SHALL treat `${CARGO_CRATE_URIS}` as list-era registry URIs **only when `CRATES` is non-empty**. When `CRATES` is empty, the rewrite SHALL preserve `GIT_CRATES` URI expansion (`${CARGO_CRATE_URIS}` as used for git crates) and SHALL preserve extra `SRC_URI` lines that are neither the GitHub/crates.io primary source nor the crates tarball (including rusty_v8 snapshot and Chromium GCS clang/rust-toolchain distfiles). The program SHALL NOT collapse those ebuilds to a two-line github-archive-plus-crates form.

#### Scenario: Assets crates URL present

- **WHEN** the manager rewrites SRC_URI for `dev-util/hk` at PV `1.50.0`
- **THEN** SRC_URI references `hk-1.50.0-crates.tar.xz` under the mndz-overlay-assets release for `hk-1.50.0`
- **AND** the primary source line is the upstream GitHub source archive

#### Scenario: CratesIo source distfile form

- **WHEN** the manager rewrites SRC_URI for `dev-util/biodiff` at any PV
- **THEN** the primary source line is `https://crates.io/api/v1/crates/biodiff/${PV}/download -> biodiff-${PV}.crate`
- **AND** the secondary line references `biodiff-${PV}-crates.tar.xz` under the mndz-overlay-assets release for `biodiff-${PV}`

#### Scenario: Empty CRATES keeps GIT_CRATES and V8 extras

- **WHEN** the manager rewrites SRC_URI for `dev-util/codex` whose ebuild has empty `CRATES`, a `GIT_CRATES` map, `${CARGO_CRATE_URIS}`, a rusty_v8 snapshot line, and Chromium GCS clang/rust-toolchain lines
- **THEN** `GIT_CRATES` URIs and the extra V8/clang/rust-toolchain lines remain
- **AND** SRC_URI is not reduced to only the GitHub archive plus `{pn}-${PV}-crates.tar.xz`

### Requirement: Cargo reuse path skips pycargoebuild

When a planned Cargo PV needs work, has a derivable reuse-write floor, is not forced full, and an assets release provides every required asset basename including `{pn}-{pv}-crates.tar.xz` and any rusty_v8 submodule sidecar required for that lock’s `v8` pin, the program SHALL reuse those assets when downloaded bytes pass expected Manifest/trusted-hash verification. Reuse SHALL NOT run pycargoebuild, manager crate packing, rusty_v8 clone, or release publication. It MAY rewrite KEYWORDS, `RUST_MIN_VER`, and SRC_URI for plan adequacy, SHALL ensure steady-state tarball shape has empty `CRATES`, then SHALL run `ebuild ... manifest` and verify as for other `DepsAndAssets` ecosystems.

If the crates release tag exists but any required asset is missing, or if the PV is forced full because no reuse-write floor is derivable, the package SHALL hard-fail before mutation because full publication cannot update, replace, or delete an existing release tag. Absence of the crates release tag SHALL permit the full path. A missing rusty_v8 snapshot for a new `v8` pin SHALL NOT by itself force the crates full path when the crates tag is absent; full-path SHALL harvest the snapshot as specified by the rusty_v8 submodule sidecar requirement.

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

#### Scenario: Existing tag missing asset hard-fails

- **WHEN** the crates release tag for a planned Cargo PV exists but `{pn}-{pv}-crates.tar.xz` is missing from that release
- **THEN** the package hard-fails before overlay mutation

### Requirement: Manager-owned crates tarball pack

For full-path Cargo materialize after successful pycargoebuild with `--no-write-crate-tarball`, the program SHALL create `{pn}-{pv}-crates.tar.xz` by: (1) parsing the provenance-appropriate `Cargo.lock` — provenance `CargoGitTag`: the clone’s lock at the policy lock root; provenance `CargoCratesIo`: the unpacked published crate’s `Cargo.lock` — for registry packages that declare a checksum; (2) for each such package, extracting the corresponding `{name}-{version}.crate` from the temporary distdir into a stage tree under `cargo_home/gentoo/{name}-{version}/` and writing `.cargo-checksum.json` with `package` set to the lockfile checksum and `files` an empty object; (3) creating the archive with system `tar` such that member paths are prefixed with `cargo_home/gentoo/…`, packing with the hermetic tar/xz rules specified by `hermetic-asset-materialize` (`XZ_OPT=-T1 -9e`, numeric owner `0/0`); (4) writing the final file atomically (temp then rename) such that the path presented to `tar` for compression **always selects xz** (the program SHALL NOT use a temporary basename whose suffix causes `tar -a` / auto-compress to skip compression—for example a bare `.tmp` suffix on an otherwise `.tar.xz` product name—unless xz is forced by an explicit xz filter flag equivalent to `-J` / `--xz`); (5) after a successful archive write and rename to the final `{pn}-{pv}-crates.tar.xz` path, verifying that the final file is an xz-compressed stream (hard-fail with an error distinct from pycargoebuild failure if the body is plain tar or otherwise not xz). Pack SHALL hard-fail if a lock-listed registry crate file is missing from the distdir or if archive creation fails, with an error distinct from pycargoebuild failure. Git/path packages that are not registry crates with checksums SHALL NOT be required in the tarball (GIT_CRATES remain pycargoebuild’s ebuild concern).

#### Scenario: Checksum JSON from lock

- **WHEN** the lock lists registry package `serde` version `1.0.200` with checksum `abc123` and the matching `.crate` is in the distdir
- **THEN** the packed tarball contains `cargo_home/gentoo/serde-1.0.200/.cargo-checksum.json` whose `package` field is `abc123`

#### Scenario: CratesIo pack includes published workspace members

- **WHEN** pack runs for a `CargoCratesIo` unit of `biodiff` at PV `1.2.1`
- **THEN** the packed tarball includes `cargo_home/gentoo/hexagex-0.2.3/` and `cargo_home/gentoo/biodiff-wfa2-sys-2.3.5/`
- **AND** the `-sys` crate directory contains the bundled WFA2-lib C sources

#### Scenario: Compression uses multi-threaded extreme xz

- **WHEN** the manager packs a crates tarball
- **THEN** the pack process uses system `tar` with `XZ_OPT` containing `-T1` and `-9e` (single-thread extreme; hermetic-asset-materialize)

#### Scenario: Atomic temp still compresses as xz

- **WHEN** pack writes via a temporary path before renaming to `{pn}-{pv}-crates.tar.xz`
- **THEN** the produced final file is xz-compressed data (not a plain POSIX tar archive)

#### Scenario: Plain tar final path hard-fails

- **WHEN** archive creation leaves a final `*.tar.xz` path whose content is not an xz stream
- **THEN** pack hard-fails before assets publish treats the file as a successful crates distfile

#### Scenario: Missing crate after pycargo hard-fails pack

- **WHEN** `Cargo.lock` lists a registry package whose `.crate` is absent from the temporary distdir after pycargoebuild
- **THEN** pack fails with an error that is not reported solely as a pycargoebuild failure

#### Scenario: Atomic final path

- **WHEN** pack succeeds
- **THEN** the final `{pn}-{pv}-crates.tar.xz` path exists as a complete file (no partial final basename left from a failed mid-write)

### Requirement: Cargo preflight tools

When any classified **full-path** unit uses `DepsAndAssets Cargo`, preflight SHALL require `docker` and a usable materialize image as specified by `hermetic-asset-materialize`. The image SHALL provide `pycargoebuild` and at least one fetcher among `wget` and `aria2c`. Preflight SHALL NOT require host `pycargoebuild`, `wget`, `aria2c`, `xz`, or `rustc` solely because a cargo package needs work. Reuse-only cargo units SHALL NOT fail preflight solely because those host tools or `docker` are missing.

#### Scenario: Missing pycargoebuild

- **WHEN** `update` selects `dev-util/mise`, a cargo unit is classified full path, and `docker` is not available
- **THEN** preflight fails before apply (image provides `pycargoebuild`; host binary is not a substitute)

#### Scenario: Missing both wget and aria2c

- **WHEN** a cargo unit is classified full path and the materialize image is unusable
- **THEN** preflight fails before package mutation (fetchers live in the image, not on the host PATH)

#### Scenario: aria2 alone does not satisfy fetcher preflight

- **WHEN** a cargo unit is classified full path and only a host binary named `aria2` (without `c`) exists
- **THEN** that host binary does not satisfy full-path cargo preflight; `docker` and the image are required

#### Scenario: Reuse-only cargo skips host pycargoebuild

- **WHEN** a cargo package needs work and every cargo unit is classified reuse
- **THEN** preflight does not fail solely because host `pycargoebuild` or a fetcher is missing

### Requirement: Soft advisory when cargo full path will use wget

The host wget/aria2 speed advisory specified previously for host-PATH `pycargoebuild` SHALL NOT be emitted solely because `aria2c` is absent from the **host** `PATH`. The materialize image SHOULD provide `aria2c`; image-internal fetcher choice is not an operator host preflight.

#### Scenario: Full-path cargo with wget only warns once

- **WHEN** `update` will full-path materialize a cargo package and `aria2c` is not on the **host** `PATH`
- **THEN** the program does not emit `pycargoebuild is using wget; install aria2 for faster crate fetches` solely for that host PATH

#### Scenario: aria2c present no advisory

- **WHEN** `update` will full-path materialize a cargo package and `aria2c` is on the host `PATH`
- **THEN** the program does not emit the wget/aria2 speed advisory solely for that package set

#### Scenario: Reuse-only cargo no advisory

- **WHEN** a cargo package needs work but every cargo unit is classified reuse (no full-path cargo materialize)
- **THEN** the program does not emit the wget/aria2 speed advisory solely for missing host `aria2c`

### Requirement: Hardcoded cargo packages enabled

The hardcoded policy map SHALL set `DepsAndAssets` with ecosystem `Cargo` for `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` with their existing GitHub sources (`jdx` / respective repos / tag prefix `v`) and provenance `CargoGitTag`, for `dev-util/biodiff` with GitHub source `8051enthusiast`/`biodiff` (tag prefix `v`) and provenance `CargoCratesIo`, and for `dev-util/codex` with GitHub source `openai`/`codex` (tag prefix `rust-v`), lock subdirectory `codex-rs`, package subdirectory `codex-rs/cli`, and provenance `CargoGitTag`. Those packages SHALL NOT remain `Unsupported` solely for cargo CRATES regeneration. Policy for `usage` SHALL use package subdirectory `cli` when required for package metadata. Policy for `codex` SHALL restrict runtime-lane arches to amd64 as specified by `runtime-lanes`.

#### Scenario: mise technique

- **WHEN** policy is resolved for `dev-util/mise`
- **THEN** the technique is `DepsAndAssets Cargo` with provenance `CargoGitTag` and the source is GitHub `jdx/mise` with tag prefix `v`

#### Scenario: usage not Unsupported

- **WHEN** policy is resolved for `dev-util/usage`
- **THEN** the technique is not `Unsupported`

#### Scenario: biodiff technique

- **WHEN** policy is resolved for `dev-util/biodiff`
- **THEN** the technique is `DepsAndAssets Cargo` with provenance `CargoCratesIo` and the source is GitHub `8051enthusiast`/`biodiff` with tag prefix `v`

#### Scenario: codex technique

- **WHEN** policy is resolved for `dev-util/codex`
- **THEN** the technique is `DepsAndAssets Cargo` with provenance `CargoGitTag`, lock subdirectory `codex-rs`, package subdirectory `codex-rs/cli`, and the source is GitHub `openai/codex` with tag prefix `rust-v`

### Requirement: CratesIo materialize from the published crate

For `DepsAndAssets Cargo` with provenance `CargoCratesIo`, full-path materialization of PV SHALL, inside the materialize container: (1) download the published crate for the policy crate name at that PV from the canonical crates.io download endpoint into the unit distdir using `aria2c` with its default User-Agent (the image-provided fetcher posture shared with pycargoebuild’s own crate fetches); (2) unpack the `.crate` into the unit `work/` source area such that the unpacked directory name matches `{p}`; (3) run `pycargoebuild` in crate-tarball mode against the unpacked crate root with the same inplace, `-M`, `--no-write-crate-tarball`, `--crate-tarball-path` (`{pn}-{pv}-crates.tar.xz`), and `--crate-tarball-prefix` (`cargo_home/gentoo`) arguments as the GitTag lane, using a temporary distdir under the unit work area; (4) pack the fetched registry crates from the unpacked crate’s `Cargo.lock` per the manager-owned crates tarball pack requirement. The program SHALL hard-fail the unit when the published crate for the PV cannot be fetched (naming the endpoint and PV), when the published crate’s package name differs from the overlay package name (naming both), or when the unpacked crate lacks `Cargo.lock`. The program SHALL NOT silently fall back to GitTag provenance or to the GitHub tag archive. The unit workspace and lifecycle SHALL follow `temp-workspace` exactly as for the GitTag lane. Full-path download, unpack, `pycargoebuild`, fetch, and pack SHALL run in the materialize container.

#### Scenario: Crate distfile fetch and unpack

- **WHEN** CratesIo materialize runs for `biodiff` at PV `1.2.1`
- **THEN** `aria2c` downloads `biodiff-1.2.1.crate` from the crates.io download endpoint with its default User-Agent
- **AND** the unpacked work source is the directory `biodiff-1.2.1/` containing `Cargo.toml` and `Cargo.lock`

#### Scenario: Missing published crate hard-fails

- **WHEN** crates.io has no published crate for the target PV
- **THEN** the unit hard-fails naming the endpoint and PV
- **AND** the program does not fall back to GitTag provenance or the GitHub tag archive

#### Scenario: Published lock drives the pack set

- **WHEN** pycargoebuild succeeds for a CratesIo unit of `biodiff` at PV `1.2.1`
- **THEN** the pack parses `biodiff-1.2.1/Cargo.lock`
- **AND** the packed tarball includes the published workspace-member crates `hexagex-0.2.3` and `biodiff-wfa2-sys-2.3.5`

#### Scenario: Name divergence hard-fails

- **WHEN** the published crate’s package name differs from the overlay package name PN
- **THEN** the unit hard-fails naming both names before ebuild or Manifest mutation

#### Scenario: pycargoebuild runs against the unpacked crate

- **WHEN** CratesIo materialize runs for `biodiff` at PV `1.2.1` and pycargoebuild succeeds
- **THEN** pycargoebuild ran against the unpacked `biodiff-1.2.1/` directory (a published crate, which carries `[package]` and no `[workspace]` table)

### Requirement: Cargo provenance coherence

Apply-time content checks SHALL enforce provenance coherence for `DepsAndAssets` Cargo packages: the policy provenance, the ebuild primary source line form, and the materialize/pack provenance SHALL agree. Provenance `CargoGitTag` requires a primary `github.com/…/archive/` source line; provenance `CargoCratesIo` requires the canonical crates.io download source line. A mismatch SHALL hard-fail the package before ebuild, Manifest, asset-publication, or commit mutation, naming the policy provenance and the observed source form.

#### Scenario: Coherent CratesIo ebuild admitted

- **WHEN** apply assesses a biodiff ebuild whose primary source line is the crates.io download distfile and policy provenance is `CargoCratesIo`
- **THEN** the coherence check passes and apply proceeds

#### Scenario: Coherence mismatch hard-fails before commit

- **WHEN** a biodiff ebuild carries a GitHub archive source line while policy provenance is `CargoCratesIo` (or the reverse mismatch)
- **THEN** apply hard-fails the package naming the expected and observed source form, before Manifest, assets publication, or commit
