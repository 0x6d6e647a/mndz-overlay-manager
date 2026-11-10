# Spec Delta

## Purpose

Product truth for the `dev-util/cargo-update` overlay package seeded at 22.1.0: crates.io source, system-library USE flags with a vendored opt-out, libsecret, man pages, gated tests, and operator acceptance through the 22.1.1 bump.

## ADDED Requirements

### Requirement: Package identity and version pin

The seeded package SHALL be `dev-util/cargo-update` at Portage version `22.1.0`, matching published crate `cargo-update` 22.1.0 and GitHub tag `v22.1.0` of `nabijaczleweli/cargo-update`. The seed ebuild SHALL NOT use `22.1.1` or any newer version. The live filename SHALL be `cargo-update-22.1.0.ebuild` without a `-r0` suffix. A content-only fix after that version has merged SHALL be a new revision (`-rN`).

#### Scenario: Filename and upstream pin

- **WHEN** the seed package is added to the overlay
- **THEN** the ebuild path is `dev-util/cargo-update/cargo-update-22.1.0.ebuild` (or `cargo-update-22.1.0-rN.ebuild` only if a content revision is required)
- **AND** that ebuild's PV is `22.1.0`, not `22.1.1`

### Requirement: crates.io source distfile

The ebuild's primary `SRC_URI` SHALL fetch `https://crates.io/api/v1/crates/cargo-update/${PV}/download -> cargo-update-${PV}.crate`. The primary source SHALL NOT be the GitHub tag archive. A second `SRC_URI` entry SHALL name the assets crates tarball `cargo-update-${PV}-crates.tar.xz`.

#### Scenario: Primary SRC_URI form

- **WHEN** the seed ebuild is inspected
- **THEN** its primary source line fetches the crates.io download for `cargo-update` parameterized by `${PV}`
- **AND** no primary source line fetches a GitHub tag archive

### Requirement: System-library USE flags

The ebuild SHALL declare `IUSE` including `+system-openssl`, `+system-libgit2`, and `+system-libcurl`, and SHALL set `REQUIRED_USE` to `system-libcurl? ( system-openssl )`. An enabled flag SHALL link that system library and SHALL NOT enable the matching vendored Cargo feature. A disabled flag SHALL enable `vendored-openssl`, `vendored-libgit2`, or `vendored-libcurl` respectively.

#### Scenario: Default links system libraries

- **WHEN** the package is built with the default USE set
- **THEN** the installed binaries' dynamic dependencies include `libgit2`, `libcurl`, and `libssl`
- **AND** the build did not enable `vendored-openssl`, `vendored-libgit2`, or `vendored-libcurl`

#### Scenario: System curl without system OpenSSL is rejected

- **WHEN** a build enables `system-libcurl` and disables `system-openssl`
- **THEN** Portage rejects the combination because of `REQUIRED_USE` before compilation starts

#### Scenario: Missing system libgit2 fails closed

- **WHEN** `system-libgit2` is enabled and no libgit2 in the 1.9 series is available
- **THEN** the build fails
- **AND** the build does not fall back to vendored libgit2

### Requirement: Conditional system dependencies

When `system-openssl` is enabled, dependencies SHALL include `dev-libs/openssl` with a subslot rebuild operator. When `system-libgit2` is enabled, dependencies SHALL accept `dev-libs/libgit2` 1.9.x and SHALL reject 1.10 and newer. When `system-libcurl` is enabled, dependencies SHALL include `net-misc/curl` with USE `http2`. Disabling a `system-*` flag SHALL drop that flag's package dependency.

#### Scenario: Vendored OpenSSL drops the OpenSSL atom

- **WHEN** the ebuild is inspected with `system-openssl` disabled and `system-libcurl` disabled
- **THEN** dependencies do not include `dev-libs/openssl`
- **AND** dependencies do not include `net-misc/curl`

### Requirement: libsecret is default on

The ebuild SHALL declare `IUSE` including `+libsecret`. When `libsecret` is enabled, runtime dependencies SHALL include `app-crypt/libsecret`. When it is disabled, they SHALL NOT include that package. Both settings SHALL install binaries that resolve `libsecret-1.so.0` only when registry auth asks for it.

#### Scenario: Default runtime dependency

- **WHEN** the ebuild is inspected with the default USE set
- **THEN** `IUSE` includes `+libsecret`
- **AND** runtime dependencies include `app-crypt/libsecret`

### Requirement: Man pages are default on

The ebuild SHALL declare `IUSE` including `+man`. When `man` is enabled, the install SHALL include `cargo-install-update.1` and `cargo-install-update-config.1` rendered from the upstream markdown, and build dependencies SHALL include `app-text/ronn-ng`. When `man` is disabled, those pages SHALL NOT be installed and `app-text/ronn-ng` SHALL NOT be required.

#### Scenario: Default man pages

- **WHEN** the package is installed with `man` enabled
- **THEN** both man pages are installed
- **AND** the build depended on `app-text/ronn-ng`

### Requirement: Test USE gate

The ebuild SHALL declare `IUSE` including `test` and SHALL set `RESTRICT` including `!test? ( test )`. When the test phase runs, it SHALL run the upstream suite shipped in the crate, offline, using the vendor crates tarball.

#### Scenario: Test flag gates the suite

- **WHEN** the ebuild is inspected
- **THEN** `IUSE` includes `test` and `RESTRICT` includes `!test? ( test )`
- **AND** a build without `test` does not run the upstream suite

### Requirement: Installed programs

The install SHALL place `cargo-install-update` and `cargo-install-update-config` in `/usr/bin`. `QA_FLAGS_IGNORED` SHALL name both of those paths. The package SHALL NOT install a library.

#### Scenario: Both subcommands are on PATH

- **WHEN** the package is installed
- **THEN** `/usr/bin/cargo-install-update` and `/usr/bin/cargo-install-update-config` exist
- **AND** no library from this package is installed

### Requirement: libssh2 and zlib stay on the system

Every USE combination SHALL depend on `net-libs/libssh2` and `sys-libs/zlib`. The ebuild SHALL NOT declare a USE flag for `libssh2`, zlib, or nghttp2.

#### Scenario: No extra vendoring flags

- **WHEN** the ebuild is inspected
- **THEN** `IUSE` does not name `libssh2`, `zlib`, or `nghttp2`
- **AND** dependencies include `net-libs/libssh2` and `sys-libs/zlib`

### Requirement: Ebuild packaging shape

The ebuild SHALL inherit `cargo` and SHALL NOT inherit `mndz-cargo`. It SHALL set `CRATES` to the empty string and SHALL NOT declare `GIT_CRATES`. It SHALL set exactly one direct `RUST_MIN_VER` to a normalized three-component version greater than or equal to `1.86.0`.

#### Scenario: Cargo eclass tarball shape

- **WHEN** the seed ebuild is inspected
- **THEN** it inherits `cargo`, sets `CRATES=""`, and does not declare `GIT_CRATES`
- **AND** `RUST_MIN_VER` is a single three-component value of at least `1.86.0`

### Requirement: Metadata and KEYWORDS

`DESCRIPTION` SHALL summarize a Cargo subcommand that checks and applies updates to installed executables. `HOMEPAGE` SHALL be `https://github.com/nabijaczleweli/cargo-update`. `metadata.xml` SHALL declare GitHub remote-id `nabijaczleweli/cargo-update` and crates.io remote-id `cargo-update`. `KEYWORDS` SHALL be exactly `~amd64 ~arm ~arm64 ~loong ~mips ~ppc ~ppc64 ~riscv ~s390 ~sparc ~x86`.

#### Scenario: Keywords and upstream identity

- **WHEN** the seed ebuild and `metadata.xml` are inspected
- **THEN** `KEYWORDS` is the broad tilde set above
- **AND** `metadata.xml` names GitHub `nabijaczleweli/cargo-update` and crates.io `cargo-update`

### Requirement: Seed crates publish

A crates tarball named `cargo-update-22.1.0-crates.tar.xz` SHALL be published to `mndz-overlay-assets` as release tag `cargo-update-22.1.0`, with `b3`, `sha256`, and `sha512` checksum sidecars committed under `dev-util/cargo-update/`. The tarball SHALL unpack with top-level directory `cargo_home/gentoo/`.

#### Scenario: Release asset name

- **WHEN** the seed assets release is inspected
- **THEN** it is tagged `cargo-update-22.1.0` and contains `cargo-update-22.1.0-crates.tar.xz`
- **AND** the matching checksum sidecars are committed under `dev-util/cargo-update/`

### Requirement: Published lock drives the seed pack

The 22.1.0 pack SHALL use the `Cargo.lock` inside the published `cargo-update` 22.1.0 crate. The pack SHALL NOT generate a lockfile and SHALL NOT clone the Git tag to obtain one.

#### Scenario: Tag has no lock

- **WHEN** the seed pack runs for PV `22.1.0`
- **THEN** the lock that is packed is the one from the published crate
- **AND** `cargo generate-lockfile` is not run

### Requirement: Manifest and md5-cache bootstrap

The overlay SHALL carry a `Manifest` generated with Portage `ebuild … manifest` against the manager private distdir, covering the crates.io source distfile and the assets crates tarball, and SHALL carry `metadata/md5-cache/dev-util/cargo-update-22.1.0`.

#### Scenario: Both distfiles are manifested

- **WHEN** the seed overlay commit is inspected
- **THEN** `Manifest` lists `cargo-update-22.1.0.crate` and `cargo-update-22.1.0-crates.tar.xz`
- **AND** `metadata/md5-cache/dev-util/cargo-update-22.1.0` is present

### Requirement: Seed emerge and smoke

The operator SHALL emerge `=dev-util/cargo-update-22.1.0` with the default USE set and without `test`. `cargo install-update --version` SHALL exit successfully and report `22.1.0`. `--help` on `cargo install-update` and `cargo install-update-config` SHALL exit successfully. `cargo install-update-config --version` is the upstream version-requirement option and SHALL NOT print the tool version. The smoke SHALL NOT invoke `cargo install-update -a`.

#### Scenario: Default seed smoke

- **WHEN** seed publish is complete and the operator emerges `=dev-util/cargo-update-22.1.0` with default USE and without `test`
- **THEN** the emerge succeeds
- **AND** `cargo install-update --version` reports `22.1.0` and both `--help` commands exit successfully
- **AND** `cargo install-update -a` was not run

### Requirement: Bump through 22.1.1

After the seed smoke, `outdated` for `dev-util/cargo-update` SHALL report `22.1.0` to `22.1.1`. `update` SHALL publish assets release `cargo-update-22.1.1` and write `cargo-update-22.1.1.ebuild` preserving `IUSE`, `REQUIRED_USE`, and both program names. The operator SHALL emerge that atom with the default USE set. `cargo install-update --version` SHALL report `22.1.1`, and `--help` on both commands SHALL exit successfully.

#### Scenario: outdated gap

- **WHEN** the operator runs `outdated` for `dev-util/cargo-update` after `22.1.0` is the newest overlay ebuild
- **THEN** the report shows `22.1.0` to `22.1.1`

#### Scenario: Default 22.1.1 install

- **WHEN** `update` has written `cargo-update-22.1.1.ebuild` and published release `cargo-update-22.1.1`
- **THEN** an emerge of `=dev-util/cargo-update-22.1.1` with the default USE set succeeds
- **AND** `cargo install-update --version` reports `22.1.1`
- **AND** the new ebuild still declares the seed `IUSE` and `REQUIRED_USE`

### Requirement: Test emerge on 22.1.1

After the default `22.1.1` smoke, the operator SHALL emerge `=dev-util/cargo-update-22.1.1` with the `test` USE flag and `FEATURES=test`, leaving the other USE flags at their defaults. That emerge SHALL run the upstream test suite and succeed. `cargo install-update --version` SHALL still report `22.1.1`, and `--help` on both commands SHALL exit successfully.

#### Scenario: FEATURES=test on the bump

- **WHEN** the operator emerges `=dev-util/cargo-update-22.1.1` with `test` enabled and `FEATURES=test` after the default 22.1.1 smoke
- **THEN** the emerge succeeds, including the upstream test suite
- **AND** `cargo install-update --version` still reports `22.1.1`

### Requirement: Vendored proof emerge

After the test emerge, the operator SHALL emerge `=dev-util/cargo-update-22.1.1` with `system-openssl`, `system-libgit2`, and `system-libcurl` disabled, leaving `libsecret` and `man` enabled. That emerge SHALL succeed without network access to crates.io. `cargo install-update --version` SHALL report `22.1.1`, and `--help` on both commands SHALL exit successfully. The installed binaries SHALL NOT list `libgit2`, `libcurl`, or `libssl` as dynamic dependencies.

#### Scenario: All three system flags off

- **WHEN** the operator emerges `=dev-util/cargo-update-22.1.1` with those three flags disabled after the test emerge
- **THEN** the emerge succeeds offline
- **AND** `cargo install-update --version` reports `22.1.1`
- **AND** the binaries' dynamic dependencies omit `libgit2`, `libcurl`, and `libssl`

### Requirement: Restore the default install

After the vendored proof, the operator SHALL emerge `=dev-util/cargo-update-22.1.1` again with the default USE set. The installed binaries SHALL link system `libgit2`, `libcurl`, and `libssl`, and `cargo install-update --version` SHALL report `22.1.1`.

#### Scenario: Host returns to system libraries

- **WHEN** the operator emerges `=dev-util/cargo-update-22.1.1` with the default USE set after the vendored proof
- **THEN** the emerge succeeds
- **AND** the binaries' dynamic dependencies include `libgit2`, `libcurl`, and `libssl`
- **AND** `cargo install-update --version` reports `22.1.1`
