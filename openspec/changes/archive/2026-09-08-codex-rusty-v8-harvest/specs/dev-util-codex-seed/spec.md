## MODIFIED Requirements

### Requirement: Extra V8 distfiles

The ebuild `SRC_URI` SHALL include, in addition to the GitHub archive and the Codex crates tarball: (1) the mndz-overlay-assets rusty_v8+submodules snapshot for the lock’s `v8` crate version (`150.4.0` at seed), downloaded from release tag `rusty-v8-${RUSTY_V8_VER}` (not from `codex-${PV}` and not from a `dev-util/`-prefixed release name); (2) the Chromium clang host tarball and Chromium rust-toolchain tarball as ordinary Portage distfiles from Chromium GCS `Linux_x64` objects matching that rusty_v8 tag’s `v8/DEPS`. Those GCS objects SHALL NOT be published to mndz-overlay-assets. Overlay `-rN` SHALL be used only when ebuild text or distfile bytes/URLs change.

#### Scenario: Seed SRC_URI has both sidecars and GCS clang

- **WHEN** the seed ebuild is inspected
- **THEN** `SRC_URI` references `codex-${PV}-crates.tar.xz` under mndz-overlay-assets tag `codex-${PV}`
- **AND** `SRC_URI` references `rusty-v8-150.4.0-with-submodules.tar.xz` under tag `rusty-v8-150.4.0`
- **AND** `SRC_URI` includes Chromium GCS `Linux_x64` clang and rust-toolchain tarballs

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
