## Purpose

Product truth for the `dev-util/biodiff` overlay package (seeded at frozen PV 1.2.0): crates.io source distfile packaging shape, USE-gated bundled WFA2 build, manually materialized offline crates assets release with checksum sidecars, build-dependency and KEYWORDS shape, offline `src_test`, and operator smoke acceptance. This is overlay/seed truth, not mndz-overlay-manager runtime behavior.

## Requirements

### Requirement: Package identity and version pin

The seeded package SHALL be `dev-util/biodiff` at Portage version `1.2.0`, corresponding to upstream `biodiff` version `1.2.0` (upstream GitHub `8051Enthusiast/biodiff` release `v1.2.0`). The seed SHALL NOT use a newer upstream version (including 1.2.1) for the initial ebuild. The live ebuild filename SHALL be `biodiff-1.2.0.ebuild` without a `-r0` suffix; content-only fixes before or after first publish SHALL use `-r1` or greater when a revision bump is required.

#### Scenario: Filename and source

- **WHEN** the seed package is added to the overlay
- **THEN** the ebuild path is `dev-util/biodiff/biodiff-1.2.0.ebuild` (or `biodiff-1.2.0-rN.ebuild` only if a content revision is required)
- **AND** the primary source distfile is the published crates.io crate for `biodiff` at that PV

### Requirement: crates.io source distfile

The ebuild's primary `SRC_URI` SHALL fetch the canonical crates.io download distfile, parameterized by `${PV}`: `https://crates.io/api/v1/crates/biodiff/${PV}/download -> biodiff-${PV}.crate`. The upstream GitHub tag archive SHALL NOT be a source distfile: the tagged source tree requires the `WFA2-lib` git submodule that tag archives exclude. The upstream GitHub release binary assets (`biodiff-linux-1.2.0.zip` and platform equivalents) SHALL NOT be referenced or installed.

#### Scenario: Primary SRC_URI form

- **WHEN** the ebuild is written
- **THEN** it contains a `SRC_URI` entry of the form `https://crates.io/api/v1/crates/biodiff/${PV}/download -> biodiff-${PV}.crate`
- **AND** no `SRC_URI` entry references a GitHub tag archive of `8051Enthusiast/biodiff` or a `biodiff-<os>-<pv>.zip` release asset

### Requirement: wfa2 USE flag and bundled WFA2 build

The ebuild SHALL declare `IUSE` including `+wfa2` (default enabled). With `wfa2` enabled the build SHALL use the upstream default feature set (bundled WFA2 through the `-sys` crate). With `wfa2` disabled the build SHALL pass `--no-default-features` so cargo resolves no `-sys` crate and the RustBio alignment backend is used. The ebuild SHALL set `QA_FLAGS_IGNORED` for `usr/bin/biodiff`.

#### Scenario: wfa2 enabled is upstream default

- **WHEN** the package is emerged with default USE flags
- **THEN** `src_configure` passes no feature-disabling arguments (upstream default features, bundled WFA2)

#### Scenario: wfa2 disabled is the pure-Rust build

- **WHEN** the package is emerged with `USE=-wfa2`
- **THEN** `src_configure` passes `--no-default-features`
- **AND** the build does not compile or link WFA2-lib

### Requirement: Build dependencies for the WFA2 era

The ebuild SHALL declare `BDEPEND="wfa2? ( dev-build/cmake llvm-core/clang:21 )"` and SHALL export `LIBCLANG_PATH` pointing at the pinned slot's libdir (`/usr/lib/llvm/21/lib64`) while building with `wfa2`. `dev-build/cmake` is required because the bundled `-sys` crate compiles WFA2-lib through CMake; the pinned `llvm-core/clang` slot supplies the libclang that the 1.2.0-era `-sys` crate's bindgen (0.69) can drive — newer libclang (22) makes that bindgen emit opaque structs and the build fails. When later PVs stop requiring bindgen, the manager's ebuild rewrite MAY carry the donor BDEPEND forward unchanged, and a content fix MAY drop the clang pin with a revision bump.

#### Scenario: BDEPEND atoms

- **WHEN** the ebuild is inspected
- **THEN** `dev-build/cmake` and `llvm-core/clang:21` appear under the `wfa2?` conditional in `BDEPEND`
- **AND** `src_configure` exports `LIBCLANG_PATH` to the pinned slot's libdir when `wfa2` is enabled
- **AND** no build dependency is unconditional that upstream only requires for the bundled WFA2 build

### Requirement: Vendor crates assets publish

A crates tarball named `biodiff-1.2.0-crates.tar.xz` SHALL be published to `mndz-overlay-assets` as release tag `biodiff-1.2.0`, with `b3`, `sha256`, and `sha512` checksum sidecars committed under `dev-util/biodiff/` in the assets repository and a GPG-signed assets commit. The tarball SHALL use the `cargo_home/gentoo/` member prefix, SHALL include the registry crates from the published crate's `Cargo.lock` — including `hexagex-0.2.3` and `biodiff-wfa2-sys-2.3.4-cf3eb92`, the latter bundling the WFA2-lib C sources — and SHALL be an xz-compressed stream packed with the hermetic tar/xz rules. The seed materialization SHALL mirror the crates.io-provenance lane steps (aria2c fetch of the published crate with its default User-Agent, unpack, pycargoebuild in crate-tarball mode with `--no-write-crate-tarball`, manager-style pack) and SHALL run in the materialize image container, not on the host toolchain. The ebuild SHALL reference the release via a fully parameterized assets `SRC_URI` using `${PV}`.

#### Scenario: Assets URL form

- **WHEN** the ebuild is written
- **THEN** it contains a `SRC_URI` entry of the form `https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/biodiff-${PV}/biodiff-${PV}-crates.tar.xz`

#### Scenario: Tarball layout

- **WHEN** the seeded crates tarball is unpacked
- **THEN** member paths are prefixed with `cargo_home/gentoo/`
- **AND** it contains `cargo_home/gentoo/hexagex-0.2.3/` and `cargo_home/gentoo/biodiff-wfa2-sys-2.3.4-cf3eb92/`
- **AND** the `-sys` crate directory contains `WFA2-lib/CMakeLists.txt`

#### Scenario: Sidecars and signing

- **WHEN** the assets release is published
- **THEN** `dev-util/biodiff/biodiff-1.2.0-crates.tar.xz.{b3,sha256,sha512}` exist in the assets worktree
- **AND** the assets commit adding them is GPG-signed

### Requirement: Crate-tarball packaging shape

The ebuild SHALL inherit `cargo`, SHALL set `CRATES` to the empty string (steady-state tarball shape, no `${CARGO_CRATE_URIS}` list), and SHALL set exactly one direct `RUST_MIN_VER` assignment carrying a valid normalized three-component version determined by the seed materialization harvest. The ebuild SHALL NOT hand-roll a `>=dev-lang/rust-...` dependency line.

#### Scenario: RUST_MIN_VER shape

- **WHEN** the ebuild is inspected
- **THEN** `CRATES` is empty
- **AND** there is exactly one direct `RUST_MIN_VER` assignment whose value is a normalized three-component Rust version

### Requirement: Metadata and KEYWORDS

The ebuild SHALL set `DESCRIPTION` to a short upstream-derived summary (visual binary file diff using sequence alignment), `HOMEPAGE` to `https://github.com/8051Enthusiast/biodiff`, and `LICENSE` to `MIT` plus the dependent crate licenses from the seed materialization. `metadata.xml` SHALL declare GitHub remote-id `8051Enthusiast/biodiff`. `KEYWORDS` SHALL be tilde-only and include `~amd64`.

#### Scenario: Metadata identity

- **WHEN** the ebuild and metadata are inspected
- **THEN** the homepage is `https://github.com/8051Enthusiast/biodiff`
- **AND** `metadata.xml` declares remote-id type `github` with value `8051Enthusiast/biodiff`
- **AND** `KEYWORDS` is tilde-only and includes `~amd64`

### Requirement: Manifest and md5-cache bootstrap

The overlay SHALL carry a `Manifest` for both distfiles (the crates.io source distfile and the assets crates tarball) generated with Portage `ebuild … manifest` against the manager private distdir, and package-scoped md5-cache under `metadata/md5-cache/`. Overlay commits adding the seed ebuild, Manifest, and md5-cache SHALL be GPG-signed.

#### Scenario: Manifest covers both distfiles

- **WHEN** `dev-util/biodiff/Manifest` is inspected
- **THEN** it contains entries for `biodiff-1.2.0.crate` and `biodiff-1.2.0-crates.tar.xz`

### Requirement: Offline src_test smoke

The ebuild SHALL include `test` in `IUSE` and set `RESTRICT` to include `!test? ( test )`. `src_test` SHALL run via the cargo eclass from the vendor crates tarball and the source distfile, and the test phase SHALL succeed without network access.

#### Scenario: offline test phase

- **WHEN** Portage runs `src_test` with network isolation
- **THEN** the phase builds from the vendor tarball offline and exits successfully

### Requirement: Operator smoke acceptance

After overlay and assets are published, the operator SHALL verify the seed by emerging `=dev-util/biodiff-1.2.0` and running `biodiff --version` and `biodiff --help`. `--version` SHALL exit successfully reporting `1.2.0`; `--help` SHALL exit successfully. This is the seed acceptance gate before the manager-driven bump to a newer upstream PV is attempted.

#### Scenario: smoke commands

- **WHEN** seed publish is complete
- **THEN** emerge of `=dev-util/biodiff-1.2.0` succeeds
- **AND** `biodiff --version` exits successfully and reports `1.2.0`
- **AND** `biodiff --help` exits successfully
