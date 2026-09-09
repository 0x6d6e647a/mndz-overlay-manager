## Purpose

Product truth for the `dev-util/codex` overlay package (seeded at frozen PV 0.153.3): from-source Codex CLI plus `codex-code-mode-host`, always-from-source rusty_v8, amd64-only KEYWORDS, crates and rusty_v8 sidecars, sandbox and protobuf dependencies, `IUSE=test`, and operator smoke acceptance. This is overlay/seed truth, not mndz-overlay-manager runtime behavior.

## Requirements

### Requirement: Package identity and version pin

The seeded package SHALL be `dev-util/codex` at Portage version `0.153.3`, corresponding to upstream tag `rust-v0.153.3` of GitHub `openai/codex`. The seed SHALL NOT use a newer upstream version (including 0.153.4) for the initial ebuild. The live ebuild filename SHALL be `codex-0.153.3.ebuild` without a `-r0` suffix; content-only fixes SHALL use `-r1` or greater when a revision bump is required. The overlay SHALL NOT add a `package.mask` of GURU `dev-util/codex`.

#### Scenario: Filename and tag

- **WHEN** the seed package is added to the overlay
- **THEN** the ebuild path is `dev-util/codex/codex-0.153.3.ebuild` (or `codex-0.153.3-rN.ebuild` only if a content revision is required)
- **AND** the primary source distfile is the GitHub archive for tag `rust-v${PV}`
- **AND** no overlay `package.mask` names `dev-util/codex`

### Requirement: Workspace unpack and S

The ebuild SHALL unpack the GitHub archive for `openai/codex` tag `rust-v${PV}` and SHALL set `S` to the `codex-rs` workspace directory under that tree (`${WORKDIR}/${PN}-rust-v${PV}/codex-rs`). `S` SHALL be human-owned template body and SHALL survive manager `SRC_URI` / `KEYWORDS` / `RUST_MIN_VER` rewrites.

#### Scenario: S points at the Cargo workspace

- **WHEN** the ebuild is inspected
- **THEN** `S` is `${WORKDIR}/${PN}-rust-v${PV}/codex-rs`

### Requirement: Always from-source V8

The package SHALL always build the `v8` crate from source (`V8_FROM_SOURCE=1`) with sandbox features enabled. The ebuild SHALL NOT offer a USE flag or environment path that downloads or installs a prebuilt `librusty_v8`. Chromium `dev-lang/v8` SHALL NOT be a dependency. The crates.io `v8` crate SHALL NOT be treated as a from-source tree.

#### Scenario: Default emerge is from-source V8

- **WHEN** the package is emerged with default USE flags under Portage `network-sandbox`
- **THEN** `src_compile` exports `V8_FROM_SOURCE=1`
- **AND** cargo does not fetch a `librusty_v8_*.a` prebuilt

### Requirement: Extra V8 distfiles

The ebuild `SRC_URI` SHALL include, in addition to the GitHub archive and the Codex crates tarball: (1) the mndz-overlay-assets rusty_v8+submodules snapshot for the lock’s `v8` crate version (`150.4.0` at seed), downloaded from release tag `rusty-v8-${RUSTY_V8_VER}` (not from `codex-${PV}` and not from a `dev-util/`-prefixed release name); (2) the Chromium clang host tarball and Chromium rust-toolchain tarball as ordinary Portage distfiles from Chromium GCS `Linux_x64` objects matching that rusty_v8 tag’s `v8/DEPS`. Those GCS objects SHALL NOT be published to mndz-overlay-assets. Overlay `-rN` SHALL be used only when ebuild text or distfile bytes/URLs change.

#### Scenario: Seed SRC_URI has both sidecars and GCS clang

- **WHEN** the seed ebuild is inspected
- **THEN** `SRC_URI` references `codex-${PV}-crates.tar.xz` under mndz-overlay-assets tag `codex-${PV}`
- **AND** `SRC_URI` references `rusty-v8-150.4.0-with-submodules.tar.xz` under tag `rusty-v8-150.4.0`
- **AND** `SRC_URI` includes Chromium GCS `Linux_x64` clang and rust-toolchain tarballs

### Requirement: Crates sidecar publish

A crates tarball named `codex-0.153.3-crates.tar.xz` SHALL be published to `mndz-overlay-assets` as release tag `codex-0.153.3`, with `b3`, `sha256`, and `sha512` checksum sidecars and a GPG-signed assets commit. The tarball SHALL use the `cargo_home/gentoo/` member prefix, SHALL contain registry crates from `codex-rs/Cargo.lock` that declare a checksum, SHALL include the incomplete crates.io `v8-150.4.0` crate if the lock lists it, and SHALL NOT pack git crates. Seed materialization SHALL run in the materialize image container.

#### Scenario: Crates tarball layout

- **WHEN** the seeded crates tarball is unpacked
- **THEN** member paths are prefixed with `cargo_home/gentoo/`
- **AND** git remotes such as `microsoft/mxc` are not packed as registry members

### Requirement: rusty_v8 submodule sidecar publish

A tarball of `denoland/rusty_v8` tag `v150.4.0` with recursive submodules SHALL be published to `mndz-overlay-assets` keyed by v8 crate version: GitHub tag and release name `rusty-v8-150.4.0`, checksum sidecars under `rusty-v8/` (not `dev-util/rusty-v8/`), commit message `rusty-v8: 150.4.0`, and a GPG-signed assets commit. The snapshot SHALL be sufficient for `V8_FROM_SOURCE=1` under `network-sandbox` (ICU data, `third_party/rust`, V8, and other submodules present). Historical seed materialization was manual; relocating sidecars and the GitHub release title from a `dev-util/` costume SHALL NOT require a new tarball or an overlay revision bump.

Git tag `codex-0.153.3` SHALL point at the assets commit that added the Codex 0.153.3 crates sidecars, not at the rusty-v8 sidecar commit.

#### Scenario: Snapshot is complete for from-source

- **WHEN** the seeded rusty_v8 snapshot is unpacked
- **THEN** it contains `third_party/icu/common/icudtl.dat`
- **AND** it contains `third_party/rust/chromium_crates_io/vendor/icu_calendar_data-v2/build.rs`

#### Scenario: Identity is not an overlay atom

- **WHEN** the 150.4.0 snapshot metadata is inspected
- **THEN** checksum sidecars live under `rusty-v8/`
- **AND** the GitHub release name is `rusty-v8-150.4.0`
- **AND** no overlay ebuild `dev-util/rusty-v8` exists

### Requirement: GIT_CRATES omit Windows-only remotes

Overlay `GIT_CRATES` SHALL list the Linux-needed git remotes from the lock (crossterm, nucleo, rules_rust runfiles, tokio-tungstenite, tungstenite) and SHALL NOT list `microsoft/mxc` or other crates that exist only under `[target.'cfg(windows)'.dependencies]`.

#### Scenario: mxc is absent

- **WHEN** the seed ebuild is inspected
- **THEN** `GIT_CRATES` has no `microsoft/mxc` entry

### Requirement: KEYWORDS amd64-only

The ebuild SHALL set `KEYWORDS="-* ~amd64"`. It SHALL NOT keyword `arm64`, `ppc64`, `riscv`, or other rust-board arches.

#### Scenario: No arm64 keyword

- **WHEN** the ebuild is inspected
- **THEN** `KEYWORDS` contains `-*` and `~amd64`
- **AND** `KEYWORDS` does not contain `arm64` or `~arm64`

### Requirement: Installed binaries

`src_compile` / `src_install` SHALL produce `/usr/bin/codex` and `/usr/bin/codex-code-mode-host` from the workspace (`--bin codex --bin codex-code-mode-host`). `QA_FLAGS_IGNORED` SHALL cover those paths.

#### Scenario: Both bins installed

- **WHEN** the seed package is emerged
- **THEN** `/usr/bin/codex --version` reports `0.153.3`
- **AND** `/usr/bin/codex-code-mode-host --help` exits 0

### Requirement: Shell completions

The ebuild SHALL offer `bash-completion`, `zsh-completion`, and `fish-completion` USE flags, inherit `shell-completion`, and install completions generated by `codex completion {bash,zsh,fish}` only when the matching flag is enabled. Elvish and powershell SHALL NOT be offered as USE flags or installed.

#### Scenario: Per-shell USE flags

- **WHEN** the ebuild is inspected
- **THEN** `IUSE` includes `bash-completion`, `zsh-completion`, and `fish-completion`
- **AND** `IUSE` does not include elvish or powershell completion flags

#### Scenario: Three shells only

- **WHEN** the seed package is emerged with all three completion USE flags enabled
- **THEN** bash, zsh, and fish completion files are installed
- **AND** elvish and powershell completion files are not installed

### Requirement: Runtime and build dependencies

`RDEPEND` SHALL include `sys-apps/bubblewrap` and `dev-libs/openssl:=`. `BDEPEND` SHALL include `dev-build/gn`, `dev-build/ninja`, `dev-libs/protobuf` (the Gentoo package that provides `/usr/bin/protoc`), a Python interpreter sufficient to run rusty_v8’s `tools/rust_toolchain.py`, and `llvm-core/clang:22` (or equivalent slot whose `lib64` provides a 64-bit `libclang.so` bindgen can load). The ebuild SHALL export `LIBCLANG_PATH` to that slot’s `lib64` during compile. Landlock SHALL NOT appear as a package dependency.

#### Scenario: bwrap and openssl

- **WHEN** the ebuild is inspected
- **THEN** `RDEPEND` includes `sys-apps/bubblewrap` and `dev-libs/openssl`
- **AND** `BDEPEND` includes `dev-build/gn`, `dev-libs/protobuf`, and `llvm-core/clang:22`

### Requirement: System protoc for gRPC codegen

`src_prepare` SHALL rewrite `code-mode-protocol/build.rs` so tonic uses `/usr/bin/protoc` (or `$PROTOC`) instead of `protoc_bin_vendored::protoc_bin_path()`. If the vendored-protoc marker is absent, `src_prepare` SHALL die. The rewrite SHALL be template-owned ebuild body, not a git-style `FILESDIR` hunk that must be rebased. `protoc-bin-vendored-*` registry crates MAY remain in the crates tarball and lock.

#### Scenario: Marker missing dies

- **WHEN** upstream `build.rs` no longer contains `protoc_bin_vendored::protoc_bin_path`
- **THEN** `src_prepare` dies rather than silently skipping the rewrite

#### Scenario: Compile uses system protoc

- **WHEN** `src_compile` runs under `network-sandbox`
- **THEN** gRPC codegen invokes system `protoc` and does not execute the vendored `bin/protoc`

### Requirement: Test USE gate

The ebuild SHALL declare `IUSE` including `test` and `RESTRICT` including `!test? ( test )`. `src_test` SHALL run a documented cargo test subset; skips SHALL be commented in the ebuild (network, sandbox, or known-failing crates). Default `USE=-test` SHALL skip the test phase.

#### Scenario: RESTRICT present

- **WHEN** the seed ebuild is inspected
- **THEN** `IUSE` includes `test`
- **AND** `RESTRICT` includes `!test? ( test )`

### Requirement: Resource floors and rustc stack

The ebuild SHALL inherit `check-reqs` with memory and disk floors of at least GURU’s 15G/20G order of magnitude, and SHALL export `RUST_MIN_STACK` of at least 16MiB during compile.

#### Scenario: check-reqs declared

- **WHEN** the ebuild is inspected
- **THEN** it inherits `check-reqs`
- **AND** `src_compile` exports `RUST_MIN_STACK`

### Requirement: Crate-tarball packaging shape

The ebuild SHALL inherit `cargo`, SHALL set `CRATES` to the empty string, SHALL retain `GIT_CRATES` plus `${CARGO_CRATE_URIS}` for git crates, and SHALL set exactly one direct `RUST_MIN_VER` assignment. The seed `RUST_MIN_VER` SHALL be at least `1.95.0` (upstream `codex-rs/rust-toolchain.toml` channel). The ebuild SHALL NOT hand-roll a `>=dev-lang/rust-...` dependency line.

#### Scenario: Empty CRATES and floor

- **WHEN** the ebuild is inspected
- **THEN** `CRATES` is empty
- **AND** `RUST_MIN_VER` is a normalized three-component version greater than or equal to `1.95.0`

### Requirement: Metadata

The ebuild SHALL set `HOMEPAGE` to `https://github.com/openai/codex`. `metadata.xml` SHALL declare GitHub remote-id `openai/codex`.

#### Scenario: Homepage and remote-id

- **WHEN** the ebuild and metadata are inspected
- **THEN** the homepage is `https://github.com/openai/codex`
- **AND** `metadata.xml` declares remote-id type `github` with value `openai/codex`

### Requirement: Manifest and md5-cache bootstrap

The overlay SHALL carry a `Manifest` for every seed distfile generated with Portage `ebuild … manifest` against the manager private distdir, and package-scoped md5-cache under `metadata/md5-cache/`. Overlay commits adding the seed ebuild, Manifest, and md5-cache SHALL be GPG-signed.

#### Scenario: Manifest covers sidecars

- **WHEN** the seed is published
- **THEN** `dev-util/codex/Manifest` contains DIST entries for the GitHub archive, the crates tarball, the rusty_v8 snapshot, and the Chromium clang and rust-toolchain tarballs
- **AND** `metadata/md5-cache/dev-util/codex-0.153.3` exists

### Requirement: Operator smoke acceptance

After the seed is installed, `emerge =dev-util/codex-0.153.3` SHALL succeed under `network-sandbox`, `codex --version` SHALL report `0.153.3`, and `codex completion bash` SHALL emit a bash completion function. After manager `update`, `emerge =dev-util/codex-0.153.4` SHALL succeed and `codex --version` SHALL report `0.153.4`.

#### Scenario: Seed emerge

- **WHEN** `=dev-util/codex-0.153.3` is emerged with default USE
- **THEN** `codex --version` reports `0.153.3`
- **AND** `codex-code-mode-host --help` exits 0

#### Scenario: Bump emerge

- **WHEN** `update` has applied 0.153.4 and `=dev-util/codex-0.153.4` is emerged
- **THEN** `codex --version` reports `0.153.4`
