# dev-util-biodiff-seed Delta

## MODIFIED Requirements

### Requirement: Vendor crates assets publish

A crates tarball named `biodiff-1.2.0-crates.tar.xz` SHALL be published to `mndz-overlay-assets` as release tag `biodiff-1.2.0`, with `b3`, `sha256`, and `sha512` checksum sidecars committed under `dev-util/biodiff/` in the assets repository and a GPG-signed assets commit. The tarball SHALL use the `cargo_home/gentoo/` member prefix, SHALL include the registry crates from the published crate's `Cargo.lock` — including `hexagex-0.2.3` and `biodiff-wfa2-sys-2.3.4-cf3eb92`, the latter bundling the WFA2-lib C sources — and SHALL be an xz-compressed stream packed with the hermetic tar/xz rules. The seed materialization SHALL mirror the crates.io-provenance lane steps (aria2c fetch of the published crate with its default User-Agent, unpack, pycargoebuild with `--use-crate-tarball`, manager-style pack) and SHALL run in the materialize image container, not on the host toolchain. The ebuild SHALL reference the release via a fully parameterized assets `SRC_URI` using `${PV}`.

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
