## ADDED Requirements

### Requirement: Cargo ecosystem under DepsAndAssets

The library SHALL support `DepsAndAssets` with ecosystem `Cargo`. Policy MAY supply an optional lock subdirectory (relative to the repository root; `Nothing` means root) where `Cargo.lock` is expected, and an optional package subdirectory for the binary package’s `Cargo.toml` / `rust-version` (`Nothing` means same as lock root). When a package subdirectory is set, full-path materialize SHALL run `pycargoebuild` with that package subdirectory as its directory argument (workspace members such as usage’s `cli/`); when unset, `pycargoebuild` SHALL run at the lock root. The program SHALL still require `Cargo.lock` at the lock root (Cargo resolves the lockfile by walking parents). Apply SHALL require a `GitHub` update source for Cargo packages and SHALL hard-fail if the source is not GitHub.

#### Scenario: usage package subdir

- **WHEN** policy for `dev-util/usage` uses `DepsAndAssets Cargo` with package subdirectory `cli` and lock at repository root
- **THEN** MSRV package metadata is read from `cli/Cargo.toml` and `pycargoebuild` runs with the `cli` directory as its directory argument (not the workspace root)

#### Scenario: hk root cargo

- **WHEN** policy for `dev-util/hk` uses `DepsAndAssets Cargo` with no subdirectories
- **THEN** both lock and package metadata are taken from the repository root and `pycargoebuild` runs at the repository root

### Requirement: pycargoebuild crate-tarball materialize

For `DepsAndAssets Cargo` full-path materialization of PV, the program SHALL: (1) clone the package’s GitHub source into a temporary directory and check out the tag formed by the source tag prefix plus that PV; (2) run `pycargoebuild` with crate-tarball mode against the package subdirectory when policy sets one, otherwise against the lock root, inplace-updating the working ebuild, without invoking `pkgdev manifest` (`-M`), writing the crate tarball to a manager-chosen path `{pn}-{pv}-crates.tar.xz` with tarball path prefix `cargo_home/gentoo`, using a temporary distdir for fetched crates; (3) not reimplement pycargoebuild’s lock parsing, crate fetch, or license logic in Haskell. The temporary clone and temp distdir SHALL be removed when the PV attempt finishes. The program SHALL NOT require host `rustc` or `cargo` for packing.

#### Scenario: Full path invokes pycargoebuild

- **WHEN** full-path materialize runs for `mise` at PV `2026.7.5`
- **THEN** the process runs `pycargoebuild` with `--crate-tarball` and a tarball path whose basename is `mise-2026.7.5-crates.tar.xz`

#### Scenario: No host rustc gate

- **WHEN** full-path cargo materialize runs on a host without `rustc` on PATH but with `pycargoebuild` and a supported fetcher
- **THEN** packing is not failed solely due to missing `rustc`

### Requirement: Cargo distfile and release naming

For Cargo packages, the program SHALL name the dependency distfile `{pn}-{pv}-crates.tar.xz` using the overlay package name PN and version PV without revision. Release tags SHALL remain `{pn}-{pv}`. The program SHALL pass this basename to pycargoebuild via `--crate-tarball-path` rather than relying on Cargo.toml package name defaults when they could differ from PN.

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

When a planned Cargo PV needs work but an assets release already provides `{pn}-{pv}-crates.tar.xz` and the downloaded bytes’ SHA512 matches the expected Manifest or trusted hash (reuse R2), the program SHALL reuse that asset without running `pycargoebuild` and without re-publishing. The program MAY still rewrite KEYWORDS, `RUST_MIN_VER`, and SRC_URI for plan adequacy, and SHALL ensure steady-state tarball shape includes empty `CRATES` (so list-era donor bodies are not left with non-empty `CRATES` on reuse), then run `ebuild … manifest` and verify as for other `DepsAndAssets` ecosystems.

#### Scenario: Clean reuse no pycargoebuild

- **WHEN** the crates asset for `usage-3.5.4-crates.tar.xz` exists on the release and SHA512 matches
- **THEN** apply does not invoke `pycargoebuild` for that unit

#### Scenario: Reuse clears list-era CRATES

- **WHEN** reuse applies for a PV whose donor ebuild still has a non-empty `CRATES` list
- **THEN** the written ebuild has empty `CRATES` suitable for crate-tarball packaging

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
