# Spec Delta

## Purpose

Product truth for the `media-gfx/photocraft` overlay package: the `0.1.1` seed, USE and runtime dependencies, install layout, licenses, offline crates assets, test gating, and headless version smoke.

## ADDED Requirements

### Requirement: Seed package identity

The seeded package SHALL be `media-gfx/photocraft` at Portage version `0.1.1`, corresponding to upstream GitHub `storytold/photocraft` tag `v0.1.1`. The initial ebuild filename SHALL be `photocraft-0.1.1.ebuild` without a `-r0` suffix. A content-only fix SHALL use `-r1` or greater when a revision bump is required.

#### Scenario: Seed filename

- **WHEN** the seed package is added to the overlay
- **THEN** the ebuild path is `media-gfx/photocraft/photocraft-0.1.1.ebuild` (or `photocraft-0.1.1-rN.ebuild` only if a content revision is required)
- **AND** the package version is `0.1.1`

### Requirement: GitHub tag archive is the primary source

The ebuild's primary `SRC_URI` SHALL fetch the GitHub tag archive of `storytold/photocraft` for tag `v${PV}`. The ebuild SHALL NOT use a crates.io crate download as its primary source.

#### Scenario: Primary SRC_URI form

- **WHEN** the ebuild is written
- **THEN** it contains a `SRC_URI` entry for `https://github.com/storytold/photocraft/archive/refs/tags/v${PV}.tar.gz`
- **AND** no `SRC_URI` entry downloads a crates.io `.crate` as the package source

### Requirement: USE flags

The ebuild SHALL declare `IUSE="+gui +cli +portal +X +wayland test"` and `REQUIRED_USE="|| ( gui cli ) gui? ( || ( X wayland ) )"`. Default USE SHALL enable `gui`, `cli`, `portal`, `X`, and `wayland`.

#### Scenario: Default USE builds both programs

- **WHEN** the package is emerged with default USE flags
- **THEN** both `gui` and `cli` are enabled
- **AND** `portal`, `X`, and `wayland` are enabled

#### Scenario: Neither program is rejected

- **WHEN** the ebuild is emerged with `USE="-gui -cli"`
- **THEN** Portage rejects the emerge because `REQUIRED_USE` demands at least one of `gui` or `cli`

#### Scenario: GUI requires a session

- **WHEN** the ebuild is emerged with `USE="gui -X -wayland"`
- **THEN** Portage rejects the emerge because `REQUIRED_USE` demands `X` or `wayland` when `gui` is set

### Requirement: GUI runtime dependencies

With `gui` enabled the ebuild SHALL RDEPEND on `sys-apps/dbus`, `x11-misc/xdg-utils`, `media-libs/libglvnd`, `media-libs/vulkan-loader`, and `x11-libs/libxkbcommon`. `portal` SHALL add `sys-apps/xdg-desktop-portal`. Without `portal` the ebuild SHALL RDEPEND on `gnome-base/zenity`. The ebuild SHALL NOT RDEPEND on a Vulkan driver package or on a specific portal backend.

#### Scenario: Portal selects the dialog provider

- **WHEN** the ebuild is inspected with `portal` enabled
- **THEN** `RDEPEND` includes `sys-apps/xdg-desktop-portal`
- **AND** `RDEPEND` does not include `gnome-base/zenity` solely because `portal` is on

#### Scenario: Disabled portal selects zenity

- **WHEN** the ebuild is inspected with `USE=-portal` and `gui` enabled
- **THEN** `RDEPEND` includes `gnome-base/zenity`
- **AND** `RDEPEND` does not include `sys-apps/xdg-desktop-portal`

### Requirement: Session library dependencies

With `X` enabled the ebuild SHALL RDEPEND on `x11-libs/libX11`, `x11-libs/libXcursor`, `x11-libs/libXi`, `x11-libs/libXrandr`, and `x11-libs/libxkbcommon[X]`. With `wayland` enabled the ebuild SHALL RDEPEND on `dev-libs/wayland`. Those dependencies SHALL be conditional on the matching flag.

#### Scenario: Wayland-only drops the X libraries

- **WHEN** the ebuild is inspected with `USE="gui wayland -X"`
- **THEN** `RDEPEND` includes `dev-libs/wayland`
- **AND** `RDEPEND` does not include `x11-libs/libX11`

### Requirement: Install layout

`gui` SHALL install `/usr/bin/photocraft`, the `ai.storyteller.photocraft` desktop file, the mime package, the hicolor icons, and the metainfo file. The installed metainfo SHALL contain the package version and a release date, not the upstream `@VERSION@` or `@DATE@` tokens. `cli` SHALL install `/usr/bin/photocraft-cli`. The ebuild SHALL NOT install `docs/brand`.

#### Scenario: Default install

- **WHEN** the package is installed with default USE
- **THEN** both `/usr/bin/photocraft` and `/usr/bin/photocraft-cli` exist
- **AND** the desktop, mime, hicolor icon, and metainfo files for `ai.storyteller.photocraft` are installed
- **AND** no path under `docs/brand` is installed

#### Scenario: CLI only

- **WHEN** the package is installed with `USE="-gui cli"`
- **THEN** `/usr/bin/photocraft-cli` exists
- **AND** `/usr/bin/photocraft` and the desktop file are absent

### Requirement: Embedded-asset licenses

The ebuild `LICENSE` SHALL include `MIT`, `Apache-2.0`, `OFL-1.1`, `ISC`, `CC0-1.0`, and `SCOWL`. The overlay SHALL provide `licenses/SCOWL`. The ebuild SHALL NOT declare an ArtCraft brand license.

#### Scenario: SCOWL license file

- **WHEN** the seed package is added
- **THEN** `licenses/SCOWL` exists in the overlay
- **AND** the ebuild `LICENSE` names `SCOWL`, `OFL-1.1`, `ISC`, and `CC0-1.0` in addition to the crate licenses

### Requirement: Seed crates release

A crates tarball named `photocraft-0.1.1-crates.tar.xz` SHALL be published to the assets repository as release tag `photocraft-0.1.1`, with `b3`, `sha256`, and `sha512` checksum sidecars and a GPG-signed assets commit, before `media-gfx/photocraft` is added to the manager policy map. The tarball SHALL use the `cargo_home/gentoo/` member prefix and the hermetic tar/xz rules. The ebuild SHALL reference that release with a `${PV}`-parameterized assets `SRC_URI`.

#### Scenario: Assets URL form

- **WHEN** the ebuild is written
- **THEN** it contains a `SRC_URI` entry of the form `https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/photocraft-${PV}/photocraft-${PV}-crates.tar.xz`

#### Scenario: Seed release exists before policy

- **WHEN** the manager policy first includes `media-gfx/photocraft`
- **THEN** assets release `photocraft-0.1.1` already contains `photocraft-0.1.1-crates.tar.xz`
- **AND** that release was not created by a policy-driven `update` while a newer comparable numeric tag existed

### Requirement: Crate-tarball ebuild shape

The ebuild SHALL inherit `cargo`, SHALL set `CRATES` to the empty string, and SHALL set exactly one direct `RUST_MIN_VER` assignment carrying the normalized three-component floor from seed materialization. The ebuild SHALL NOT hand-roll a `>=dev-lang/rust-...` dependency line.

#### Scenario: Steady-state CRATES

- **WHEN** the seed ebuild is inspected
- **THEN** `CRATES` is empty
- **AND** exactly one `RUST_MIN_VER` assignment is present

### Requirement: Seed keywords match the allowlist

The seed ebuild SHALL set `KEYWORDS="-* ~amd64 ~x86 ~arm ~arm64 ~ppc64 ~loong ~riscv ~sparc ~s390"`. It SHALL NOT keyword `ppc` or `mips`.

#### Scenario: Keyword string

- **WHEN** the seed ebuild is inspected
- **THEN** `KEYWORDS` is `-* ~amd64 ~x86 ~arm ~arm64 ~ppc64 ~loong ~riscv ~sparc ~s390`

### Requirement: Headless version smoke

Installed `photocraft --version` and `photocraft-cli --version` SHALL print a version and exit 0 without opening a display. The GUI smoke applies only when `photocraft` is installed.

#### Scenario: Both binaries answer --version

- **WHEN** the default-USE install is invoked as `photocraft --version` and `photocraft-cli --version`
- **THEN** each command prints a version and exits 0
- **AND** neither command requires a display server
