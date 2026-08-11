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

For `DepsAndAssets Cargo` full-path materialization of PV, the program SHALL: (1) clone the package’s GitHub source into the unit `work/` directory under the product temporary workspace defined by `temp-workspace` and check out the tag formed by the source tag prefix plus that PV; (2) run `pycargoebuild` with crate-tarball mode against the package subdirectory when policy sets one, otherwise against the lock root, inplace-updating the working ebuild, without invoking `pkgdev manifest` (`-M`), with `--no-write-crate-tarball` so pycargoebuild does not create the crates archive, passing a manager-chosen `--crate-tarball-path` whose basename is `{pn}-{pv}-crates.tar.xz` and `--crate-tarball-prefix` `cargo_home/gentoo`, using a temporary distdir under the unit work area for fetched crates; (3) after pycargoebuild succeeds, pack the fetched registry crates into that tarball path under the unit `out/` (or equivalent staged output) as specified by the manager-owned crates tarball pack requirement; (4) not reimplement pycargoebuild’s crate fetch or license logic in Haskell. The program MAY parse `Cargo.lock` for packing and for MSRV. The temporary clone, temp distdir, and pack stage tree SHALL follow the `temp-workspace` unit lifecycle (delete the unit tree on success or soft-skip; retain on hard-fail with path in the error). The program SHALL NOT require host `rustc` or `cargo` for packing.

#### Scenario: Full path invokes pycargoebuild

- **WHEN** full-path materialize runs for `mise` at PV `2026.7.5`
- **THEN** the process runs `pycargoebuild` with `--crate-tarball`, `--no-write-crate-tarball`, and a tarball path whose basename is `mise-2026.7.5-crates.tar.xz`

#### Scenario: Full path pack produces the crates tarball

- **WHEN** full-path materialize runs for `mise` at PV `2026.7.5` and pycargoebuild succeeds
- **THEN** the manager writes `mise-2026.7.5-crates.tar.xz` at the planned path and does not rely on pycargoebuild to create that file

#### Scenario: No host rustc gate

- **WHEN** full-path cargo materialize runs on a host without `rustc` on PATH but with `pycargoebuild`, a supported fetcher, and `xz`
- **THEN** packing is not failed solely due to missing `rustc`

### Requirement: Cargo distfile and release naming

For Cargo packages, the program SHALL name the dependency distfile `{pn}-{pv}-crates.tar.xz` using the overlay package name PN and version PV without revision. Release tags SHALL remain `{pn}-{pv}`. The program SHALL pass this basename to pycargoebuild via `--crate-tarball-path` (for tarball mode / empty CRATES metadata) and SHALL write that same basename when packing after pycargoebuild, rather than relying on Cargo.toml package name defaults when they could differ from PN.

#### Scenario: mise crates name

- **WHEN** publishing assets for package `mise` at PV `2026.7.5`
- **THEN** the distfile basename is `mise-2026.7.5-crates.tar.xz` and the release tag is `mise-2026.7.5`

### Requirement: MSRV probe and RUST_MIN_VER

For each Cargo candidate or apply PV, the program SHALL determine a minimum Rust version as follows: (1) read `package.rust-version` from the policy package `Cargo.toml` when present; (2) on full path, compute the maximum of declared `package.rust-version` values among `Cargo.lock` packages and workspace members whose manifests are available after clone/crate fetch; (3) take the maximum of the values from (1), (2) when computed, and any existing donor ebuild `RUST_MIN_VER` so a higher known floor is never lowered; (4) if no value is obtained, hard-fail that PV or plan unit. Versions SHALL be normalized to three numeric components for comparison and for writing `RUST_MIN_VER` (e.g. `1.91` becomes `1.91.0`). The manager SHALL write `RUST_MIN_VER` into the ebuild and SHALL NOT invent a hand-rolled `>=dev-lang/rust-…` BDEPEND line for the toolchain (rust/cargo eclass owns expansion to `|| ( rust-bin rust )`).

#### Scenario: Root rust-version present

- **WHEN** `hk` Cargo.toml declares `rust-version = "1.88.0"` and no dependency declares a higher value
- **THEN** the ebuild receives `RUST_MIN_VER="1.88.0"`

#### Scenario: Missing root rust-version uses max deps and donor

- **WHEN** the package `Cargo.toml` has no `rust-version`, full path finds a max dependency `rust-version` of `1.90.0`, and the donor ebuild has `RUST_MIN_VER="1.95.0"`
- **THEN** the written `RUST_MIN_VER` is `1.95.0`

#### Scenario: No MSRV signal hard-fails

- **WHEN** no root `rust-version`, no dependency `rust-version`, and no donor `RUST_MIN_VER` are available
- **THEN** the cargo unit or plan fails without writing an empty or eclass-default-only min

### Requirement: Manager-owned SRC_URI for cargo

After pycargoebuild inplace update on full path (or on content repair), the program SHALL ensure the ebuild `SRC_URI` includes the upstream GitHub source archive for the tag and the mndz-overlay-assets crates tarball URL for `{pn}-${PV}-crates.tar.xz`, and SHALL NOT rely on `${CARGO_CRATE_URIS}` as the dependency distfile source for steady-state tarball-shaped ebuilds.

#### Scenario: Assets crates URL present

- **WHEN** the manager rewrites SRC_URI for `dev-util/hk` at PV `1.50.0`
- **THEN** SRC_URI references `hk-1.50.0-crates.tar.xz` under the mndz-overlay-assets release for `hk-1.50.0`

### Requirement: Cargo reuse path skips pycargoebuild

When a planned Cargo PV needs work but an assets release already provides `{pn}-{pv}-crates.tar.xz` and the downloaded bytes’ SHA512 matches the expected Manifest or trusted hash (reuse R2), the program SHALL reuse that asset without running `pycargoebuild`, without running manager crate packing, and without re-publishing. The program MAY still rewrite KEYWORDS, `RUST_MIN_VER`, and SRC_URI for plan adequacy, and SHALL ensure steady-state tarball shape includes empty `CRATES` (so list-era donor bodies are not left with non-empty `CRATES` on reuse), then run `ebuild … manifest` and verify as for other `DepsAndAssets` ecosystems.

#### Scenario: Clean reuse no pycargoebuild

- **WHEN** the crates asset for `usage-3.5.4-crates.tar.xz` exists on the release and SHA512 matches
- **THEN** apply does not invoke `pycargoebuild` for that unit

#### Scenario: Clean reuse no manager crate pack

- **WHEN** the crates asset for `usage-3.5.4-crates.tar.xz` exists on the release and SHA512 matches
- **THEN** apply does not run manager crate packing for that unit

#### Scenario: Reuse clears list-era CRATES

- **WHEN** reuse applies for a PV whose donor ebuild still has a non-empty `CRATES` list
- **THEN** the written ebuild has empty `CRATES` suitable for crate-tarball packaging

### Requirement: Manager-owned crates tarball pack

For full-path Cargo materialize after successful pycargoebuild with `--no-write-crate-tarball`, the program SHALL create `{pn}-{pv}-crates.tar.xz` by: (1) parsing `Cargo.lock` at the policy lock root for registry packages that declare a checksum; (2) for each such package, extracting the corresponding `{name}-{version}.crate` from the temporary distdir into a stage tree under `cargo_home/gentoo/{name}-{version}/` and writing `.cargo-checksum.json` with `package` set to the lockfile checksum and `files` an empty object; (3) creating the archive with system `tar` such that member paths are prefixed with `cargo_home/gentoo/…`, compressing with environment `XZ_OPT=-T0 -9e` (multi-threaded extreme xz); (4) writing the final file atomically (temp then rename) such that the path presented to `tar` for compression **always selects xz** (the program SHALL NOT use a temporary basename whose suffix causes `tar -a` / auto-compress to skip compression—for example a bare `.tmp` suffix on an otherwise `.tar.xz` product name—unless xz is forced by an explicit xz filter flag equivalent to `-J` / `--xz`); (5) after a successful archive write and rename to the final `{pn}-{pv}-crates.tar.xz` path, verifying that the final file is an xz-compressed stream (hard-fail with an error distinct from pycargoebuild failure if the body is plain tar or otherwise not xz). Pack SHALL hard-fail if a lock-listed registry crate file is missing from the distdir or if archive creation fails, with an error distinct from pycargoebuild failure. Git/path packages that are not registry crates with checksums SHALL NOT be required in the tarball (GIT_CRATES remain pycargoebuild’s ebuild concern).

#### Scenario: Checksum JSON from lock

- **WHEN** the lock lists registry package `serde` version `1.0.200` with checksum `abc123` and the matching `.crate` is in the distdir
- **THEN** the packed tarball contains `cargo_home/gentoo/serde-1.0.200/.cargo-checksum.json` whose `package` field is `abc123`

#### Scenario: Compression uses multi-threaded extreme xz

- **WHEN** the manager packs a crates tarball
- **THEN** the pack process uses system `tar` with `XZ_OPT` containing `-T0` and `-9e` (or equivalent extreme multi-thread settings)

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

When any selected package uses `DepsAndAssets Cargo`, preflight SHALL require `pycargoebuild` on PATH and at least one fetcher usable by pycargoebuild among `wget` and `aria2c` (or `aria2`). Failure SHALL hard-fail before package work with a message that names the missing tool(s). Preflight SHALL NOT require host `rustc` solely for cargo packaging.

#### Scenario: Missing pycargoebuild

- **WHEN** `update` selects `dev-util/mise` and `pycargoebuild` is not executable on PATH
- **THEN** preflight fails before apply

### Requirement: Hardcoded cargo packages enabled

The hardcoded policy map SHALL set `DepsAndAssets` with ecosystem `Cargo` for `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` with their existing GitHub sources (`jdx` / respective repos / tag prefix `v`). Those packages SHALL NOT remain `Unsupported` solely for cargo CRATES regeneration. Policy for `usage` SHALL use package subdirectory `cli` when required for package metadata.

#### Scenario: mise technique

- **WHEN** policy is resolved for `dev-util/mise`
- **THEN** the technique is `DepsAndAssets Cargo` and the source is GitHub `jdx/mise` with tag prefix `v`

#### Scenario: usage not Unsupported

- **WHEN** policy is resolved for `dev-util/usage`
- **THEN** the technique is not `Unsupported`
