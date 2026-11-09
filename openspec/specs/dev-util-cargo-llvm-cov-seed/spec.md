## Purpose

Product truth for the `dev-util/cargo-llvm-cov` overlay package seeded at frozen PV 0.9.0: GitHub tag archive, a lock generated because the tag omits `Cargo.lock`, an LLVM wrapper, gated upstream tests, and operator acceptance through the 0.9.1 bump.

## Requirements

### Requirement: Package identity and version pin

The seeded package SHALL be `dev-util/cargo-llvm-cov` at Portage version `0.9.0`, matching upstream tag `v0.9.0` of `taiki-e/cargo-llvm-cov`. The seed ebuild SHALL NOT use `0.9.1` or any newer upstream version. The live filename SHALL be `cargo-llvm-cov-0.9.0.ebuild` without a `-r0` suffix. A content-only fix after that version has merged SHALL be a new revision (`-rN`).

#### Scenario: Filename and upstream pin

- **WHEN** the seed package is added to the overlay
- **THEN** the ebuild path is `dev-util/cargo-llvm-cov/cargo-llvm-cov-0.9.0.ebuild` (or `cargo-llvm-cov-0.9.0-rN.ebuild` only if a content revision is required)
- **AND** that ebuild's PV is `0.9.0`, not `0.9.1`

### Requirement: GitHub tag archive source

The ebuild's primary `SRC_URI` SHALL fetch the GitHub tag archive `https://github.com/taiki-e/cargo-llvm-cov/archive/refs/tags/v${PV}.tar.gz -> ${P}.tar.gz`. The primary source SHALL NOT be the crates.io `.crate` download and SHALL NOT be a GitHub release binary archive.

#### Scenario: Primary SRC_URI form

- **WHEN** the seed ebuild is inspected
- **THEN** it contains `https://github.com/taiki-e/cargo-llvm-cov/archive/refs/tags/v${PV}.tar.gz -> ${P}.tar.gz`
- **AND** no `SRC_URI` entry fetches `crates.io` or a `cargo-llvm-cov-*-unknown-linux-*.tar.gz` release asset

### Requirement: Test USE gate only

The ebuild SHALL declare `IUSE` including `test` and SHALL set `RESTRICT` including `!test? ( test )`. It SHALL NOT declare a USE flag that switches nextest, browser opening, or C/C++ coverage.

#### Scenario: IUSE is test plus eclass flags

- **WHEN** the ebuild is inspected
- **THEN** `IUSE` includes `test` and `RESTRICT` includes `!test? ( test )`
- **AND** `IUSE` does not name `nextest`, `open`, or `ffi`

### Requirement: LLVM install layout

The Cargo-built binary SHALL be installed at `/usr/libexec/cargo-llvm-cov/cargo-llvm-cov`. `/usr/bin/cargo-llvm-cov` SHALL be a wrapper that execs that binary. `RDEPEND` SHALL include unslotted `llvm-core/llvm`. `QA_FLAGS_IGNORED` SHALL include `usr/libexec/cargo-llvm-cov/cargo-llvm-cov`.

#### Scenario: Command path is the wrapper

- **WHEN** the package is installed
- **THEN** `/usr/bin/cargo-llvm-cov` is the wrapper
- **AND** the built binary is `/usr/libexec/cargo-llvm-cov/cargo-llvm-cov`
- **AND** `RDEPEND` includes unslotted `llvm-core/llvm`

### Requirement: LLVM tool lookup

When `LLVM_COV` or `LLVM_PROFDATA` is unset, the wrapper SHALL set each unset variable from the LLVM major reported by `rustc -vV`: `/usr/lib/llvm/<major>/bin/llvm-cov` and `llvm-profdata`. A variable that is already set SHALL be left unchanged. When a path the wrapper would set does not exist, the wrapper SHALL exit non-zero without starting the real binary and SHALL name that `rustc` and the LLVM version it reported.

#### Scenario: Unset variables follow rustc

- **WHEN** `/usr/bin/cargo-llvm-cov` runs and neither `LLVM_COV` nor `LLVM_PROFDATA` is set
- **THEN** the real binary sees both variables pointing at `llvm-cov` and `llvm-profdata` under `/usr/lib/llvm/<major>/bin` for the LLVM major reported by `rustc -vV`

#### Scenario: Caller values win

- **WHEN** the wrapper runs with both `LLVM_COV` and `LLVM_PROFDATA` already set
- **THEN** those values are unchanged when the real binary starts

#### Scenario: Missing slot fails closed

- **WHEN** the wrapper must set `LLVM_COV` and `/usr/lib/llvm/<major>/bin/llvm-cov` does not exist
- **THEN** the wrapper exits non-zero
- **AND** the error names that `rustc` and the LLVM version from `rustc -vV`
- **AND** the real binary does not start

### Requirement: Offline git dev-dependency

`src_prepare` SHALL rewrite the `test-helper` git dependency in `Cargo.toml` to the unpacked `GIT_CRATES` directory before Cargo runs. The rewrite SHALL fail the build when that git pin is absent. An offline build SHALL NOT clone `test-helper`.

#### Scenario: Path rewrite before compile

- **WHEN** Portage prepares the unpacked tag
- **THEN** `Cargo.toml` names a path to the unpacked `test-helper` tree
- **AND** that path is the `GIT_CRATES` commit directory
- **AND** Cargo does not clone `https://github.com/taiki-e/test-helper.git`

### Requirement: Gated upstream test phase

`src_test` SHALL run only when the `test` USE flag is enabled. Before `cargo test`, the phase SHALL make the unpacked source a git work tree that tracks `tests/fixtures/crates`, including fixture dotfiles, and SHALL export `LLVM_COV` and `LLVM_PROFDATA` to the same slot paths the wrapper uses. `cargo test` SHALL skip `trybuild` and `ui_test`. `BDEPEND` SHALL include `test? ( dev-vcs/git )`. The phase SHALL succeed with network access disabled.

#### Scenario: Offline test phase

- **WHEN** Portage runs `src_test` for this package with the `test` USE flag enabled and network access disabled
- **THEN** the phase exits successfully
- **AND** the `cargo test` invocation skips `trybuild` and `ui_test`

#### Scenario: Tests stay off by default

- **WHEN** the package is emerged without the `test` USE flag
- **THEN** Portage does not run `src_test`

### Requirement: Generated-lock crates publish

A crates tarball named `cargo-llvm-cov-0.9.0-crates.tar.xz` SHALL be published to `mndz-overlay-assets` as release tag `cargo-llvm-cov-0.9.0`, with `b3`, `sha256`, and `sha512` sidecars under `dev-util/cargo-llvm-cov/` and a GPG-signed assets commit. Unpacked members SHALL use the `cargo_home/gentoo/` prefix. The assets `SRC_URI` SHALL be `https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/cargo-llvm-cov-${PV}/cargo-llvm-cov-${PV}-crates.tar.xz`.

#### Scenario: Assets URL and layout

- **WHEN** the seed ebuild and the published tarball are inspected
- **THEN** the ebuild references `cargo-llvm-cov-${PV}-crates.tar.xz` on the `cargo-llvm-cov-${PV}` assets release
- **AND** unpacked tarball members are prefixed with `cargo_home/gentoo/`
- **AND** the three checksum sidecars exist in the assets worktree

### Requirement: Lock generated from the tag

The seed pack SHALL run in the materialize image from a clone of tag `v0.9.0`. That tag has no `Cargo.lock`, so the image SHALL generate one from the tag's `Cargo.toml` before `pycargoebuild --use-crate-tarball` and the manager crates pack. The generated lock SHALL pin git crate `test-helper` at revision `82e3b012a49fb16587e165986674290ef682a5b0`. The ebuild SHALL declare that crate in `GIT_CRATES`, SHALL include `SRC_URI+=" ${CARGO_CRATE_URIS}"`, and SHALL set `CRATES` to empty.

#### Scenario: Git dev-dependency is fetched via GIT_CRATES

- **WHEN** the seed ebuild is inspected
- **THEN** `GIT_CRATES` names `test-helper` from `https://github.com/taiki-e/test-helper.git` at revision `82e3b012a49fb16587e165986674290ef682a5b0`
- **AND** `SRC_URI` contains `${CARGO_CRATE_URIS}`
- **AND** `CRATES` is empty

### Requirement: Ebuild packaging shape

The ebuild SHALL inherit `cargo` and SHALL set exactly one direct `RUST_MIN_VER` to a normalized three-component version greater than or equal to `1.87.0`. It SHALL NOT hand-roll a `dev-lang/rust` dependency. `HOMEPAGE` SHALL be `https://github.com/taiki-e/cargo-llvm-cov`. `DESCRIPTION` SHALL describe a Cargo subcommand for LLVM source-based code coverage. `LICENSE` SHALL contain `|| ( Apache-2.0 MIT )` and the dependent-crate licenses from the seed pack.

#### Scenario: Identity fields

- **WHEN** the seed ebuild is inspected
- **THEN** `HOMEPAGE` is `https://github.com/taiki-e/cargo-llvm-cov`
- **AND** `LICENSE` contains `|| ( Apache-2.0 MIT )`
- **AND** there is exactly one direct `RUST_MIN_VER` assignment whose value is a normalized three-component version at least `1.87.0`

### Requirement: Metadata and KEYWORDS

`metadata.xml` SHALL declare GitHub remote-id `taiki-e/cargo-llvm-cov` and a crates.io remote-id `cargo-llvm-cov`. `KEYWORDS` SHALL be exactly `~amd64 ~arm ~arm64 ~loong ~mips ~ppc ~ppc64 ~riscv ~s390 ~sparc ~x86`.

#### Scenario: Metadata identity

- **WHEN** `metadata.xml` and the ebuild are inspected
- **THEN** `metadata.xml` declares remote-id type `github` with value `taiki-e/cargo-llvm-cov`
- **AND** `metadata.xml` declares remote-id type `crates` with value `cargo-llvm-cov`
- **AND** `KEYWORDS` is `~amd64 ~arm ~arm64 ~loong ~mips ~ppc ~ppc64 ~riscv ~s390 ~sparc ~x86`

### Requirement: Manifest and md5-cache bootstrap

The overlay SHALL carry a `Manifest` generated with Portage `ebuild … manifest` against the manager private distdir, covering the GitHub tag archive, the assets crates tarball, and the `test-helper` git distfile. Package-scoped md5-cache SHALL exist under `metadata/md5-cache/`. Overlay commits that add the seed ebuild, Manifest, and md5-cache SHALL be GPG-signed.

#### Scenario: Manifest covers the seed distfiles

- **WHEN** `dev-util/cargo-llvm-cov/Manifest` is inspected after the seed publish
- **THEN** it contains a `cargo-llvm-cov-0.9.0.tar.gz` entry, a `cargo-llvm-cov-0.9.0-crates.tar.xz` entry, and a distfile entry for the `test-helper` git revision
- **AND** `metadata/md5-cache/dev-util/cargo-llvm-cov-0.9.0` exists

### Requirement: Seed emerge and smoke

The operator SHALL emerge `=dev-util/cargo-llvm-cov-0.9.0` without the `test` USE flag. `cargo llvm-cov --version` SHALL exit successfully and report `0.9.0`. In a temporary directory, `cargo new --lib` of a crate with no dependencies, followed by `cargo llvm-cov` with `LLVM_COV` and `LLVM_PROFDATA` unset, SHALL exit successfully.

#### Scenario: Default emerge smoke

- **WHEN** seed publish is complete and the operator emerges `=dev-util/cargo-llvm-cov-0.9.0` without `test`
- **THEN** the emerge succeeds
- **AND** `cargo llvm-cov --version` exits successfully and reports `0.9.0`
- **AND** `cargo llvm-cov` on a new no-dependency library, with `LLVM_COV` and `LLVM_PROFDATA` unset, exits successfully

### Requirement: Seed test emerge

Before `outdated` is accepted for this package, the operator SHALL emerge `=dev-util/cargo-llvm-cov-0.9.0` again with `FEATURES=test`. That emerge SHALL succeed. The same version and no-dependency `cargo llvm-cov` smokes SHALL pass afterward with `LLVM_COV` and `LLVM_PROFDATA` unset.

#### Scenario: FEATURES=test on the seed

- **WHEN** the operator emerges `=dev-util/cargo-llvm-cov-0.9.0` with `FEATURES=test` after the default emerge smoke
- **THEN** the emerge succeeds, including `src_test`
- **AND** `cargo llvm-cov --version` still reports `0.9.0`
- **AND** `cargo llvm-cov` on a new no-dependency library, with both LLVM variables unset, exits successfully

### Requirement: Bump through 0.9.1

After the seed test emerge, `outdated` for `dev-util/cargo-llvm-cov` SHALL report `0.9.0` to `0.9.1`. `update` for that package SHALL publish assets release `cargo-llvm-cov-0.9.1` and SHALL write `cargo-llvm-cov-0.9.1.ebuild` while preserving the wrapper, `IUSE`, `RDEPEND`, and `src_test`. The operator SHALL emerge `=dev-util/cargo-llvm-cov-0.9.1` without `test`, repeat both smokes expecting version `0.9.1`, then emerge that same atom with `FEATURES=test` and repeat both smokes again.

#### Scenario: outdated gap

- **WHEN** the operator runs `outdated` for `dev-util/cargo-llvm-cov` after the 0.9.0 seed is the newest overlay ebuild
- **THEN** the report shows `0.9.0` to `0.9.1`

#### Scenario: Updated install and test emerge

- **WHEN** `update` has written `cargo-llvm-cov-0.9.1.ebuild` and published release `cargo-llvm-cov-0.9.1`
- **THEN** an emerge of `=dev-util/cargo-llvm-cov-0.9.1` without `test` succeeds and `cargo llvm-cov --version` reports `0.9.1`
- **AND** a later emerge of that atom with `FEATURES=test` succeeds
- **AND** the 0.9.1 ebuild still installs `/usr/bin/cargo-llvm-cov` as the LLVM wrapper and still skips `trybuild` and `ui_test` in `src_test`
