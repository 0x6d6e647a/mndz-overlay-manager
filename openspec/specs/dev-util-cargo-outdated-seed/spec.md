# dev-util-cargo-outdated-seed Specification

## Purpose

Product truth for the `dev-util/cargo-outdated` overlay package seeded at 0.18.0: crates.io source, six default-on system-library USE flags with a fenced vendored opt-out, libsecret, gated tests, and operator acceptance through the 0.19.0 bump.

## Requirements

### Requirement: Package identity and version pin

The seeded package SHALL be `dev-util/cargo-outdated` at Portage version `0.18.0`, matching published crate `cargo-outdated` 0.18.0 and GitHub tag `v0.18.0` of `kbknapp/cargo-outdated`. The seed ebuild SHALL NOT use `0.19.0` or any newer version. The live filename SHALL be `cargo-outdated-0.18.0.ebuild` without a `-r0` suffix. A content-only fix after that version has merged SHALL be a new revision (`-rN`).

#### Scenario: Filename and upstream pin

- **WHEN** the seed package is added to the overlay
- **THEN** the ebuild path is `dev-util/cargo-outdated/cargo-outdated-0.18.0.ebuild` (or `cargo-outdated-0.18.0-rN.ebuild` only if a content revision is required)
- **AND** that ebuild's PV is `0.18.0`, not `0.19.0`

### Requirement: crates.io source distfile

The ebuild's primary `SRC_URI` SHALL fetch `https://crates.io/api/v1/crates/cargo-outdated/${PV}/download -> cargo-outdated-${PV}.crate`. The primary source SHALL NOT be the GitHub tag archive. A second `SRC_URI` entry SHALL name the assets crates tarball `cargo-outdated-${PV}-crates.tar.xz`.

#### Scenario: Primary SRC_URI form

- **WHEN** the seed ebuild is inspected
- **THEN** its primary source line fetches the crates.io download for `cargo-outdated` parameterized by `${PV}`
- **AND** no primary source line fetches a GitHub tag archive

### Requirement: System-library USE flags

The ebuild SHALL declare `IUSE` including `+system-openssl`, `+system-libcurl`, `+system-libgit2`, `+system-libssh2`, `+system-zlib`, and `+system-sqlite`. An enabled flag SHALL link that library from the system. A disabled flag SHALL build and statically link the copy bundled in the crates tarball.

#### Scenario: Default links system libraries

- **WHEN** the package is built with the default USE set
- **THEN** the installed binary's dynamic dependencies include `libssl`, `libcurl`, `libgit2`, `libssh2`, `libz`, and `libsqlite3`

#### Scenario: Missing system libgit2 fails closed

- **WHEN** `system-libgit2` is enabled and no libgit2 in the accepted series is available
- **THEN** the build fails
- **AND** the build does not fall back to the bundled libgit2

### Requirement: REQUIRED_USE fence

`REQUIRED_USE` SHALL reject every combination in which a system library would load a second OpenSSL or zlib copy, or in which a bundled library would never be linked. It SHALL be exactly the four rules `!system-openssl? ( !system-libcurl !system-libgit2 !system-libssh2 )`, `!system-libcurl? ( !system-openssl )`, `system-libgit2? ( system-libssh2 )`, and `!system-zlib? ( !system-libcurl )`.

#### Scenario: Bundled OpenSSL with a system consumer is rejected

- **WHEN** a build disables `system-openssl` and leaves `system-libcurl`, `system-libgit2`, or `system-libssh2` enabled
- **THEN** Portage rejects the combination before compilation starts

#### Scenario: Bundled curl requires bundled OpenSSL

- **WHEN** a build disables `system-libcurl` and leaves `system-openssl` enabled
- **THEN** Portage rejects the combination before compilation starts

#### Scenario: Bundled libssh2 under system libgit2 is rejected

- **WHEN** a build enables `system-libgit2` and disables `system-libssh2`
- **THEN** Portage rejects the combination before compilation starts

#### Scenario: Bundled zlib requires every zlib consumer bundled

- **WHEN** a build disables `system-zlib` and leaves `system-libcurl` enabled
- **THEN** Portage rejects the combination before compilation starts

#### Scenario: libgit2 escape hatch is allowed

- **WHEN** a build disables `system-libgit2` and `system-libssh2` and leaves the other flags at their defaults
- **THEN** Portage accepts the combination

#### Scenario: Fully bundled build is allowed

- **WHEN** a build disables all six `system-*` flags
- **THEN** Portage accepts the combination

### Requirement: Conditional system dependencies

Each enabled `system-*` flag SHALL add its package to build and runtime dependencies, and a disabled flag SHALL drop it: `dev-libs/openssl` with a subslot rebuild operator; `net-misc/curl` with USE `http2` and `ssl`; `dev-libs/libgit2` accepting 1.9.2 and newer 1.9.x and rejecting 1.10 and newer, with a subslot operator; `net-libs/libssh2` and `sys-libs/zlib` with subslot operators; `dev-db/sqlite` slot 3.

#### Scenario: Default dependencies

- **WHEN** the ebuild is inspected with the default USE set
- **THEN** dependencies include all six system packages above

#### Scenario: Fully bundled drops every library atom

- **WHEN** the ebuild is inspected with all six `system-*` flags disabled
- **THEN** dependencies include none of `dev-libs/openssl`, `net-misc/curl`, `dev-libs/libgit2`, `net-libs/libssh2`, `sys-libs/zlib`, or `dev-db/sqlite`

### Requirement: Bundled OpenSSL build tool

When `system-openssl` is disabled, build dependencies SHALL include `dev-lang/perl`. When it is enabled, `dev-lang/perl` SHALL NOT be a build dependency of this package. Build dependencies SHALL include `virtual/pkgconfig` and SHALL NOT include `dev-build/cmake`.

#### Scenario: Perl only for bundled OpenSSL

- **WHEN** the ebuild is inspected with `system-openssl` disabled
- **THEN** build dependencies include `dev-lang/perl`
- **AND** with `system-openssl` enabled they do not

### Requirement: libsecret is default on

The ebuild SHALL declare `IUSE` including `+libsecret`. When `libsecret` is enabled, runtime dependencies SHALL include `app-crypt/libsecret`. When it is disabled, they SHALL NOT include that package. The binary SHALL NOT link `libsecret` at build time.

#### Scenario: Default runtime dependency

- **WHEN** the ebuild is inspected with the default USE set
- **THEN** `IUSE` includes `+libsecret`
- **AND** runtime dependencies include `app-crypt/libsecret`

### Requirement: Test USE gate

The ebuild SHALL declare `IUSE` including `test` and SHALL set `RESTRICT` including `!test? ( test )`. When the test phase runs, it SHALL run the upstream unit tests shipped in the crate, offline, using the vendor crates tarball.

#### Scenario: Test flag gates the suite

- **WHEN** the ebuild is inspected
- **THEN** `IUSE` includes `test` and `RESTRICT` includes `!test? ( test )`
- **AND** a build without `test` does not run the upstream tests

### Requirement: Installed program

The install SHALL place `cargo-outdated` in `/usr/bin`. `QA_FLAGS_IGNORED` SHALL name that path. The package SHALL NOT install a library, man pages, or shell completions.

#### Scenario: Subcommand is on PATH

- **WHEN** the package is installed
- **THEN** `/usr/bin/cargo-outdated` exists
- **AND** no library from this package is installed

### Requirement: No other vendoring or upstream debug flags

The ebuild SHALL NOT declare a USE flag for nghttp2, dbus, `man`, or upstream's `debug` Cargo feature, and SHALL NOT enable that `debug` feature.

#### Scenario: IUSE stays at the decided set

- **WHEN** the ebuild is inspected
- **THEN** `IUSE` is exactly the six `system-*` flags, `+libsecret`, and `test`

### Requirement: Ebuild packaging shape

The ebuild SHALL inherit `cargo` and SHALL NOT inherit `mndz-cargo`. It SHALL set `CRATES` to the empty string and SHALL NOT declare `GIT_CRATES`. It SHALL set exactly one direct `RUST_MIN_VER` to a normalized three-component version greater than or equal to the crate's `rust-version`.

#### Scenario: Cargo eclass tarball shape

- **WHEN** the seed ebuild is inspected
- **THEN** it inherits `cargo`, sets `CRATES=""`, and does not declare `GIT_CRATES`
- **AND** `RUST_MIN_VER` is a single three-component value of at least `1.84.0`

### Requirement: Metadata and KEYWORDS

`DESCRIPTION` SHALL summarize a Cargo subcommand that displays when dependencies are out of date. `HOMEPAGE` SHALL be `https://github.com/kbknapp/cargo-outdated`. `LICENSE` SHALL include `MIT`. `metadata.xml` SHALL declare GitHub remote-id `kbknapp/cargo-outdated`, crates.io remote-id `cargo-outdated`, and a description for every local USE flag. `KEYWORDS` SHALL be exactly `~amd64 ~arm ~arm64 ~loong ~mips ~ppc ~ppc64 ~riscv ~s390 ~sparc ~x86`.

#### Scenario: Keywords and upstream identity

- **WHEN** the seed ebuild and `metadata.xml` are inspected
- **THEN** `KEYWORDS` is the broad tilde set above
- **AND** `metadata.xml` names GitHub `kbknapp/cargo-outdated` and crates.io `cargo-outdated`
- **AND** `metadata.xml` describes each `system-*` flag and `libsecret`

### Requirement: Seed crates publish

A crates tarball named `cargo-outdated-0.18.0-crates.tar.xz` SHALL be published to `mndz-overlay-assets` as release tag `cargo-outdated-0.18.0`, with `b3`, `sha256`, and `sha512` checksum sidecars committed under `dev-util/cargo-outdated/`. The tarball SHALL unpack with top-level directory `cargo_home/gentoo/`.

#### Scenario: Release asset name

- **WHEN** the seed assets release is inspected
- **THEN** it is tagged `cargo-outdated-0.18.0` and contains `cargo-outdated-0.18.0-crates.tar.xz`
- **AND** the matching checksum sidecars are committed under `dev-util/cargo-outdated/`

### Requirement: Published lock drives the seed pack

The 0.18.0 pack SHALL use the `Cargo.lock` inside the published `cargo-outdated` 0.18.0 crate. The pack SHALL NOT generate a lockfile and SHALL NOT clone the Git tag to obtain one.

#### Scenario: Crate lock is packed

- **WHEN** the seed pack runs for PV `0.18.0`
- **THEN** the lock that is packed is the one from the published crate
- **AND** `cargo generate-lockfile` is not run

### Requirement: Manifest and md5-cache bootstrap

The overlay SHALL carry a `Manifest` generated with Portage `ebuild … manifest` against the manager private distdir, covering the crates.io source distfile and the assets crates tarball, and SHALL carry `metadata/md5-cache/dev-util/cargo-outdated-0.18.0`.

#### Scenario: Both distfiles are manifested

- **WHEN** the seed overlay commit is inspected
- **THEN** `Manifest` lists `cargo-outdated-0.18.0.crate` and `cargo-outdated-0.18.0-crates.tar.xz`
- **AND** `metadata/md5-cache/dev-util/cargo-outdated-0.18.0` is present

### Requirement: Functional smoke

A smoke SHALL run `cargo outdated --version` and `cargo outdated --help`, both exiting successfully, with the version output containing the installed PV. It SHALL then run `cargo outdated` in a throwaway crate that depends on `libc = "0.1"`, with a temporary `CARGO_HOME`. That run SHALL exit successfully and list `libc` as out of date. The smoke SHALL NOT modify the operator's Cargo home or any real project.

#### Scenario: Smoke against the crates.io index

- **WHEN** the smoke runs after an emerge
- **THEN** `--version` reports the installed PV and `--help` exits successfully
- **AND** `cargo outdated` in the throwaway crate exits successfully and its report includes `libc`

### Requirement: Seed emerge and smoke

The operator SHALL emerge `=dev-util/cargo-outdated-0.18.0` with the default USE set and without `test`. The functional smoke SHALL pass and report `0.18.0`.

#### Scenario: Default seed smoke

- **WHEN** seed publish is complete and the operator emerges `=dev-util/cargo-outdated-0.18.0` with default USE and without `test`
- **THEN** the emerge succeeds
- **AND** the functional smoke passes and reports `0.18.0`

### Requirement: Bump through 0.19.0

After the seed smoke, `outdated` for `dev-util/cargo-outdated` SHALL report `0.18.0` to `0.19.0`. `update` SHALL publish assets release `cargo-outdated-0.19.0` and write `cargo-outdated-0.19.0.ebuild` preserving `IUSE`, `REQUIRED_USE`, and the program name. The operator SHALL emerge that atom with the default USE set, and the functional smoke SHALL pass and report `0.19.0`.

#### Scenario: outdated gap

- **WHEN** the operator runs `outdated` for `dev-util/cargo-outdated` after `0.18.0` is the newest overlay ebuild
- **THEN** the report shows `0.18.0` to `0.19.0`

#### Scenario: Default 0.19.0 install

- **WHEN** `update` has written `cargo-outdated-0.19.0.ebuild` and published release `cargo-outdated-0.19.0`
- **THEN** an emerge of `=dev-util/cargo-outdated-0.19.0` with the default USE set succeeds
- **AND** the functional smoke passes and reports `0.19.0`
- **AND** the new ebuild still declares the seed `IUSE` and `REQUIRED_USE`

### Requirement: Test emerge on 0.19.0

After the default `0.19.0` smoke, the operator SHALL emerge `=dev-util/cargo-outdated-0.19.0` with the `test` USE flag and `FEATURES=test`, leaving the other USE flags at their defaults. That emerge SHALL run the upstream tests and succeed, and the functional smoke SHALL pass and report `0.19.0`.

#### Scenario: FEATURES=test on the bump

- **WHEN** the operator emerges `=dev-util/cargo-outdated-0.19.0` with `test` enabled and `FEATURES=test` after the default 0.19.0 smoke
- **THEN** the emerge succeeds, including the upstream tests
- **AND** the functional smoke passes and reports `0.19.0`

### Requirement: Fully bundled proof emerge

After the test emerge, the operator SHALL emerge `=dev-util/cargo-outdated-0.19.0` with all six `system-*` flags disabled and `libsecret` enabled. That emerge SHALL succeed offline, and the functional smoke SHALL pass and report `0.19.0`. The binary SHALL NOT list `libssl`, `libcrypto`, `libcurl`, `libgit2`, `libssh2`, `libz`, or `libsqlite3` as dynamic dependencies.

#### Scenario: All six system flags off

- **WHEN** the operator emerges `=dev-util/cargo-outdated-0.19.0` with all six `system-*` flags disabled after the test emerge
- **THEN** the emerge succeeds offline
- **AND** the functional smoke passes and reports `0.19.0`
- **AND** the binary's dynamic dependencies omit every library listed above

### Requirement: Restore the default install

After the fully bundled proof, the operator SHALL emerge `=dev-util/cargo-outdated-0.19.0` again with the default USE set. The binary SHALL link the system `libssl`, `libcurl`, `libgit2`, `libssh2`, `libz`, and `libsqlite3`, and the functional smoke SHALL pass and report `0.19.0`.

#### Scenario: Host returns to system libraries

- **WHEN** the operator emerges `=dev-util/cargo-outdated-0.19.0` with the default USE set after the fully bundled proof
- **THEN** the emerge succeeds
- **AND** the binary's dynamic dependencies include the six system libraries above
- **AND** the functional smoke passes and reports `0.19.0`
