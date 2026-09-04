## Purpose

Cargo ecosystem under `DepsAndAssets`: pycargoebuild crate-tarball materialize, manager-owned crates tarball pack, distfile naming, MSRV probe, SRC_URI/`RUST_MIN_VER` ownership, policy for hk/mise/usage, preflight tools, and reuse vs full path.

## Requirements

### Requirement: Cargo ecosystem under DepsAndAssets

The library SHALL support `DepsAndAssets` with ecosystem `Cargo`. Policy MAY supply an optional lock subdirectory (relative to the repository root; `Nothing` means root) where `Cargo.lock` is expected, and an optional package subdirectory for the binary package’s `Cargo.toml` / `rust-version` (`Nothing` means same as lock root). When a package subdirectory is set, full-path materialize SHALL run `pycargoebuild` with that package subdirectory as its directory argument (workspace members such as usage’s `cli/`); when unset, `pycargoebuild` SHALL run at the lock root. The program SHALL still require `Cargo.lock` at the lock root (Cargo resolves the lockfile by walking parents). Apply SHALL require a `GitHub` update source for Cargo packages and SHALL hard-fail if the source is not GitHub.

#### Scenario: usage package subdir

- **WHEN** policy for `dev-util/usage` uses `DepsAndAssets Cargo` with package subdirectory `cli` and lock at repository root
- **THEN** MSRV package metadata is read from `cli/Cargo.toml` and `pycargoebuild` runs with the `cli` directory as its directory argument (not the workspace root)

#### Scenario: hk root cargo

- **WHEN** policy for `dev-util/hk` uses `DepsAndAssets Cargo` with no subdirectories
- **THEN** both lock and package metadata are taken from the repository root and `pycargoebuild` runs at the repository root

### Requirement: pycargoebuild crate-tarball materialize

For `DepsAndAssets Cargo` full-path materialization of PV, the program SHALL: (1) clone the package’s GitHub source into the unit `work/` directory under the product temporary workspace defined by `temp-workspace` and check out the tag formed by the source tag prefix plus that PV; (2) run `pycargoebuild` with crate-tarball mode against the package subdirectory when policy sets one, otherwise against the lock root, inplace-updating the working ebuild, without invoking `pkgdev manifest` (`-M`), with `--no-write-crate-tarball` so pycargoebuild does not create the crates archive, passing a manager-chosen `--crate-tarball-path` whose basename is `{pn}-{pv}-crates.tar.xz` and `--crate-tarball-prefix` `cargo_home/gentoo`, using a temporary distdir under the unit work area for fetched crates; (3) after pycargoebuild succeeds, pack the fetched registry crates into that tarball path under the unit `out/` as specified by the manager-owned crates tarball pack requirement; (4) not reimplement pycargoebuild’s crate fetch or license logic in Haskell. The program MAY parse `Cargo.lock` for packing and for MSRV. The temporary clone, temp distdir, and pack stage tree SHALL follow the `temp-workspace` unit lifecycle (delete the unit tree on success or soft-skip; retain on hard-fail with path in the error). Full-path clone, `pycargoebuild`, fetch, and pack SHALL run in the materialize container. The program SHALL NOT require host `rustc`, `cargo`, `pycargoebuild`, or `xz` for packing.

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

### Requirement: Manager-owned SRC_URI for cargo

After pycargoebuild inplace update on full path (or on content repair), the program SHALL ensure the ebuild `SRC_URI` includes the upstream GitHub source archive for the tag and the mndz-overlay-assets crates tarball URL for `{pn}-${PV}-crates.tar.xz`, and SHALL NOT rely on `${CARGO_CRATE_URIS}` as the dependency distfile source for steady-state tarball-shaped ebuilds.

#### Scenario: Assets crates URL present

- **WHEN** the manager rewrites SRC_URI for `dev-util/hk` at PV `1.50.0`
- **THEN** SRC_URI references `hk-1.50.0-crates.tar.xz` under the mndz-overlay-assets release for `hk-1.50.0`

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

### Requirement: Manager-owned crates tarball pack

For full-path Cargo materialize after successful pycargoebuild with `--no-write-crate-tarball`, the program SHALL create `{pn}-{pv}-crates.tar.xz` by: (1) parsing `Cargo.lock` at the policy lock root for registry packages that declare a checksum; (2) for each such package, extracting the corresponding `{name}-{version}.crate` from the temporary distdir into a stage tree under `cargo_home/gentoo/{name}-{version}/` and writing `.cargo-checksum.json` with `package` set to the lockfile checksum and `files` an empty object; (3) creating the archive with system `tar` such that member paths are prefixed with `cargo_home/gentoo/…`, packing with the hermetic tar/xz rules specified by `hermetic-asset-materialize` (`XZ_OPT=-T1 -9e`, numeric owner `0/0`); (4) writing the final file atomically (temp then rename) such that the path presented to `tar` for compression **always selects xz** (the program SHALL NOT use a temporary basename whose suffix causes `tar -a` / auto-compress to skip compression—for example a bare `.tmp` suffix on an otherwise `.tar.xz` product name—unless xz is forced by an explicit xz filter flag equivalent to `-J` / `--xz`); (5) after a successful archive write and rename to the final `{pn}-{pv}-crates.tar.xz` path, verifying that the final file is an xz-compressed stream (hard-fail with an error distinct from pycargoebuild failure if the body is plain tar or otherwise not xz). Pack SHALL hard-fail if a lock-listed registry crate file is missing from the distdir or if archive creation fails, with an error distinct from pycargoebuild failure. Git/path packages that are not registry crates with checksums SHALL NOT be required in the tarball (GIT_CRATES remain pycargoebuild’s ebuild concern).

#### Scenario: Checksum JSON from lock

- **WHEN** the lock lists registry package `serde` version `1.0.200` with checksum `abc123` and the matching `.crate` is in the distdir
- **THEN** the packed tarball contains `cargo_home/gentoo/serde-1.0.200/.cargo-checksum.json` whose `package` field is `abc123`

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

The hardcoded policy map SHALL set `DepsAndAssets` with ecosystem `Cargo` for `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` with their existing GitHub sources (`jdx` / respective repos / tag prefix `v`). Those packages SHALL NOT remain `Unsupported` solely for cargo CRATES regeneration. Policy for `usage` SHALL use package subdirectory `cli` when required for package metadata.

#### Scenario: mise technique

- **WHEN** policy is resolved for `dev-util/mise`
- **THEN** the technique is `DepsAndAssets Cargo` and the source is GitHub `jdx/mise` with tag prefix `v`

#### Scenario: usage not Unsupported

- **WHEN** policy is resolved for `dev-util/usage`
- **THEN** the technique is not `Unsupported`
