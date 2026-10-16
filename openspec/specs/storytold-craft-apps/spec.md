# storytold-craft-apps Specification

## Purpose

Product truth for the twelve Storytold craft apps: package identity, USE and dependencies, install layout, offline crates assets, and headless version smoke.

## Requirements

### Requirement: Craft app inventory

The overlay SHALL ship each package below from GitHub owner `storytold`, repository equal to the package name, tag prefix `v`. The primary `SRC_URI` SHALL be that tag archive. The ebuild SHALL NOT use a crates.io `.crate` as its primary source.

#### Scenario: Eleven apps are present

- **WHEN** the overlay inventory is inspected
- **THEN** it contains `app-office/deckcraft`, `app-office/designcraft`, `app-office/gridcraft`, `app-office/wordcraft`, `app-text/pdfcraft`, `media-gfx/cadcraft`, `media-gfx/lightcraft`, `media-gfx/vectorcraft`, `media-sound/soundcraft`, `media-video/effectcraft`, and `media-video/filmcraft`
- **AND** each primary `SRC_URI` fetches `https://github.com/storytold/<package-name>/archive/refs/tags/v${PV}.tar.gz`
- **AND** no primary `SRC_URI` downloads a crates.io `.crate`

### Requirement: Shared USE contract

Each craft app ebuild SHALL declare `IUSE="+gui +cli +portal +X +wayland test"` and `REQUIRED_USE="|| ( gui cli ) gui? ( || ( X wayland ) )"`. Default USE SHALL enable `gui`, `cli`, `portal`, `X`, and `wayland`.

#### Scenario: Default USE builds both programs

- **WHEN** a craft app is emerged with default USE flags
- **THEN** both `gui` and `cli` are enabled
- **AND** `portal`, `X`, and `wayland` are enabled

#### Scenario: Neither program is rejected

- **WHEN** a craft app is emerged with `USE="-gui -cli"`
- **THEN** Portage rejects the emerge because `REQUIRED_USE` demands at least one of `gui` or `cli`

#### Scenario: GUI requires a session

- **WHEN** a craft app is emerged with `USE="gui -X -wayland"`
- **THEN** Portage rejects the emerge because `REQUIRED_USE` demands `X` or `wayland` when `gui` is set

### Requirement: Per-app USE flags

LightCraft SHALL add `+heif` and default-off `rawnind-model`. FilmCraft SHALL add default-off `whisper`, `neural-voices`, `vaapi`, and `nvenc`. PdfCraft SHALL add default-off `cups`. EffectCraft SHALL add one of those FilmCraft flags only when its app crate exposes that feature.

#### Scenario: heif defaults on

- **WHEN** LightCraft is emerged with default USE
- **THEN** `heif` is enabled
- **AND** compile passes `--features heif` for both the GUI and CLI packages

#### Scenario: rawnind-model defaults off

- **WHEN** LightCraft is emerged with default USE
- **THEN** `rawnind-model` is disabled
- **AND** compile does not pass `--features rawnind-model`
- **AND** `LICENSE` does not include `GPL-3`

#### Scenario: rawnind-model enables the downloader

- **WHEN** LightCraft is emerged with `USE=rawnind-model`
- **THEN** compile passes `--features rawnind-model`
- **AND** `LICENSE` does not include `GPL-3`

#### Scenario: FilmCraft optional flags default off

- **WHEN** FilmCraft is emerged with default USE
- **THEN** `whisper`, `neural-voices`, `vaapi`, and `nvenc` are disabled
- **AND** compile does not pass those feature names
- **AND** `RDEPEND` does not include `media-libs/libva` or `x11-drivers/nvidia-drivers`

#### Scenario: FilmCraft optional flags opt in

- **WHEN** FilmCraft is emerged with `whisper`, `neural-voices`, `vaapi`, and `nvenc` enabled
- **THEN** compile passes the `whisper` and `neural-voices` features for both programs
- **AND** `vaapi` adds `RDEPEND` on `media-libs/libva` and does not add a build dependency
- **AND** `nvenc` adds `RDEPEND` on `x11-drivers/nvidia-drivers` and does not add a build dependency

#### Scenario: cups defaults off

- **WHEN** PdfCraft is emerged with default USE
- **THEN** `cups` is disabled
- **AND** `RDEPEND` does not include `net-print/cups`

#### Scenario: cups opts in

- **WHEN** PdfCraft is emerged with `USE=cups`
- **THEN** `RDEPEND` includes `net-print/cups`

#### Scenario: EffectCraft omits a missing feature

- **WHEN** EffectCraft's app crate does not expose `whisper`, `neural-voices`, `vaapi`, or `nvenc`
- **THEN** the ebuild does not declare that flag

### Requirement: GUI runtime dependencies

With `gui` enabled, each craft app SHALL RDEPEND on `sys-apps/dbus`, `x11-misc/xdg-utils`, `media-libs/libglvnd`, `media-libs/vulkan-loader`, and `x11-libs/libxkbcommon`. `portal` SHALL add `sys-apps/xdg-desktop-portal`. Without `portal`, `gui` SHALL RDEPEND on `gnome-base/zenity`. The ebuild SHALL NOT RDEPEND on a Vulkan driver package or a portal backend.

#### Scenario: Portal selects the dialog provider

- **WHEN** a craft app ebuild is inspected with `portal` enabled
- **THEN** `RDEPEND` includes `sys-apps/xdg-desktop-portal`
- **AND** `RDEPEND` does not include `gnome-base/zenity` solely because `portal` is on

#### Scenario: Disabled portal selects zenity

- **WHEN** a craft app ebuild is inspected with `USE=-portal` and `gui` enabled
- **THEN** `RDEPEND` includes `gnome-base/zenity`
- **AND** `RDEPEND` does not include `sys-apps/xdg-desktop-portal`

### Requirement: GPU libraries for video CLIs

EffectCraft and FilmCraft SHALL RDEPEND on `media-libs/libglvnd` and `media-libs/vulkan-loader` whether or not `gui` is enabled. They SHALL NOT RDEPEND on a Vulkan driver package.

#### Scenario: CLI-only video app still links the loaders

- **WHEN** EffectCraft or FilmCraft is inspected with `USE="-gui cli"`
- **THEN** `RDEPEND` includes `media-libs/libglvnd` and `media-libs/vulkan-loader`

### Requirement: Session library dependencies

With `X` enabled, each craft app SHALL RDEPEND on `x11-libs/libX11`, `x11-libs/libXcursor`, `x11-libs/libXi`, `x11-libs/libXrandr`, and `x11-libs/libxkbcommon[X]`. With `wayland` enabled, it SHALL RDEPEND on `dev-libs/wayland`. Those dependencies SHALL be conditional on the matching flag.

#### Scenario: Wayland-only drops the X libraries

- **WHEN** a craft app ebuild is inspected with `USE="gui wayland -X"`
- **THEN** `RDEPEND` includes `dev-libs/wayland`
- **AND** `RDEPEND` does not include `x11-libs/libX11`

### Requirement: ALSA for audio GUIs

DeckCraft, SoundCraft, EffectCraft, and FilmCraft SHALL DEPEND and RDEPEND on `media-libs/alsa-lib` when `gui` is enabled. They SHALL NOT declare a `jack` or `pipewire` USE flag.

#### Scenario: GUI audio app links ALSA

- **WHEN** one of those four ebuilds is inspected with `gui` enabled
- **THEN** `DEPEND` and `RDEPEND` include `media-libs/alsa-lib`

#### Scenario: CLI-only audio app drops ALSA

- **WHEN** DeckCraft or SoundCraft is inspected with `USE="-gui cli"`
- **THEN** `DEPEND` and `RDEPEND` do not include `media-libs/alsa-lib`

### Requirement: PdfCraft native build tools

PdfCraft SHALL BDEPEND on `dev-build/cmake` and `dev-lang/nasm`. It SHALL NOT depend on poppler or mupdf. It SHALL NOT declare a `mcp` USE flag.

#### Scenario: Signing support builds offline

- **WHEN** the PdfCraft ebuild is inspected
- **THEN** `BDEPEND` includes `dev-build/cmake` and `dev-lang/nasm`
- **AND** no dependency atom names poppler or mupdf
- **AND** `IUSE` does not include `mcp`

### Requirement: Compile and install selection

Each craft app SHALL pass `-p <name>` and `-p <name>-cli` from `src_compile` according to `gui` and `cli`, and SHALL keep those arguments out of `ECARGO_ARGS`. `src_install` SHALL install the matching binaries.

#### Scenario: Both programs are selected explicitly

- **WHEN** a craft app is built with default USE
- **THEN** compile invokes cargo with `-p <name>` and `-p <name>-cli`
- **AND** `ECARGO_ARGS` does not contain `-p`

### Requirement: Install layout

`gui` SHALL install `/usr/bin/<name>`, the `ai.storyteller.<name>` desktop file, the mime package, the hicolor icons that the tag ships, and the metainfo file. The installed metainfo SHALL contain the package version and a release date, not the upstream `@VERSION@` or `@DATE@` tokens. `cli` SHALL install `/usr/bin/<name>-cli`. The ebuild SHALL NOT install `docs/brand`. CADCraft SHALL NOT require a scalable icon directory.

#### Scenario: Default install

- **WHEN** a craft app is installed with default USE
- **THEN** both `/usr/bin/<name>` and `/usr/bin/<name>-cli` exist
- **AND** the desktop, mime, hicolor icon, and metainfo files for `ai.storyteller.<name>` are installed
- **AND** no path under `docs/brand` is installed

#### Scenario: CADCraft has no scalable icons

- **WHEN** CADCraft is installed
- **THEN** the hicolor PNG sizes shipped by the tag are installed
- **AND** install succeeds without a scalable icon directory

#### Scenario: CLI only

- **WHEN** a craft app is installed with `USE="-gui cli"`
- **THEN** `/usr/bin/<name>-cli` exists
- **AND** `/usr/bin/<name>` and the desktop file are absent

### Requirement: Embedded-asset licenses

Each ebuild `LICENSE` SHALL use `|| ( MIT Apache-2.0 )` for the app. Extra licenses for files the ebuild installs or embeds SHALL sit in a `LICENSE+=` after the generated crate-license block. The ebuild SHALL NOT declare an ArtCraft brand license. LightCraft SHALL NOT add `GPL-3` for `rawnind-model`.

#### Scenario: Extra license line follows the generated block

- **WHEN** a craft app ebuild is inspected
- **THEN** `|| ( MIT Apache-2.0 )` is present
- **AND** any non-crate asset license is assigned with `LICENSE+=` after the generated crate-license block
- **AND** `LICENSE` does not name an ArtCraft brand license

### Requirement: Shared font embed

A craft app whose tag contains `crates/fonts/build.rs` SHALL BDEPEND on `media-fonts/craft-fonts:=` and SHALL export `CRAFT_FONTS_DIR=/usr/share/craft-fonts` and `CRAFT_FONTS_REQUIRED=1` during compile. An app without that build script SHALL NOT set `CRAFT_FONTS_DIR`.

#### Scenario: Font crate embeds the shared checkout

- **WHEN** a craft app tag contains `crates/fonts/build.rs`
- **THEN** `BDEPEND` includes `media-fonts/craft-fonts:=`
- **AND** compile exports `CRAFT_FONTS_DIR=/usr/share/craft-fonts` and `CRAFT_FONTS_REQUIRED=1`

#### Scenario: App without the font crate stays unset

- **WHEN** a craft app tag has no `crates/fonts/build.rs`
- **THEN** the ebuild does not set `CRAFT_FONTS_DIR`

### Requirement: Crate-tarball ebuild shape

Each craft app ebuild SHALL inherit `cargo`, SHALL set `CRATES` to the empty string, and SHALL set exactly one direct `RUST_MIN_VER` assignment. The ebuild SHALL NOT hand-roll a `>=dev-lang/rust-...` dependency line. Its crates `SRC_URI` SHALL fetch `{pn}-${PV}-crates.tar.xz` from the assets repository.

#### Scenario: Steady-state CRATES

- **WHEN** a craft app ebuild is inspected
- **THEN** `CRATES` is empty
- **AND** exactly one `RUST_MIN_VER` assignment is present
- **AND** a `SRC_URI` entry has the form `https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/<pn>-${PV}/<pn>-${PV}-crates.tar.xz`

### Requirement: Keywords match the allowlist

Each craft app ebuild SHALL set `KEYWORDS="-* ~amd64 ~x86 ~arm ~arm64 ~ppc64 ~loong ~riscv ~sparc ~s390"`. It SHALL NOT keyword `ppc` or `mips`.

#### Scenario: Keyword string

- **WHEN** a craft app ebuild is inspected
- **THEN** `KEYWORDS` is `-* ~amd64 ~x86 ~arm ~arm64 ~ppc64 ~loong ~riscv ~sparc ~s390`

### Requirement: Predecessor crates release

Before a craft app enters the policy map, the assets repository SHALL already contain release `<pn>-<PV>` for the previous comparable numeric tag, including `<pn>-<PV>-crates.tar.xz` and `b3`, `sha256`, and `sha512` sidecars. That release SHALL NOT be created by a policy-driven `update` while a newer comparable numeric tag exists.

#### Scenario: Seed release exists before policy

- **WHEN** the manager policy first includes one of the eleven apps
- **THEN** the assets release for that package's previous comparable numeric tag already contains its crates tarball and checksum sidecars
- **AND** that release was not created by a policy-driven `update` while a newer comparable numeric tag existed

### Requirement: Metadata for local flags

Each craft app `metadata.xml` SHALL document the local flags `cli` and `portal`, plus `heif` and `rawnind-model` on LightCraft, `whisper` and `neural-voices` on FilmCraft, and `nvenc` wherever that flag is declared. It SHALL name `maintainer-needed`. It SHALL NOT document a global USE flag.

#### Scenario: Local flags are documented

- **WHEN** a craft app `metadata.xml` is inspected
- **THEN** it documents `cli` and `portal`
- **AND** it does not document `gui`, `X`, `wayland`, `test`, or `cups`

### Requirement: Headless version smoke

Installed `<name> --version` and `<name>-cli --version` SHALL print a version and exit 0 without opening a display. The GUI smoke applies only when `<name>` is installed.

#### Scenario: Both binaries answer --version

- **WHEN** the default-USE install is invoked as `<name> --version` and `<name>-cli --version`
- **THEN** each command prints a version and exits 0
- **AND** neither command requires a display server

### Requirement: EffectCraft keeps Linux git crates

EffectCraft's Linux git dependencies SHALL remain in `GIT_CRATES`. Windows-only and wasm-only git crates SHALL be omitted.

#### Scenario: Filmcraft pins survive on Linux

- **WHEN** the EffectCraft ebuild is inspected after a Cargo rewrite
- **THEN** `GIT_CRATES` includes the Linux `filmcraft-*` git crates from that tag's lock
- **AND** `GIT_CRATES` omits windows-only and wasm-only git crates

### Requirement: FigCraft joins the craft inventory

The overlay SHALL ship `media-gfx/figcraft` from GitHub owner `storytold`, repository `figcraft`, tag prefix `v`. The primary `SRC_URI` SHALL be that tag archive. The ebuild SHALL NOT use a crates.io `.crate` as its primary source.

#### Scenario: FigCraft is present

- **WHEN** the overlay inventory is inspected
- **THEN** it contains `media-gfx/figcraft`
- **AND** its primary `SRC_URI` fetches `https://github.com/storytold/figcraft/archive/refs/tags/v${PV}.tar.gz`
- **AND** that primary `SRC_URI` does not download a crates.io `.crate`

### Requirement: FigCraft omits the collaboration server

FigCraft SHALL compile and install only the programs selected by `gui` and `cli`. It SHALL NOT install `figcraft-server`. Workspace `src_test` SHALL exclude `figcraft-web` and `xtask` and SHALL NOT exclude `figcraft-server`.

#### Scenario: Server binary is absent

- **WHEN** FigCraft is installed with default USE
- **THEN** `/usr/bin/figcraft` and `/usr/bin/figcraft-cli` exist
- **AND** `/usr/bin/figcraft-server` does not exist

#### Scenario: Workspace tests still include the server crate

- **WHEN** `USE=test` and `FEATURES=test` run `src_test` for FigCraft
- **THEN** the phase excludes `figcraft-web` and `xtask`
- **AND** the phase does not exclude `figcraft-server`
- **AND** the phase does not pass a package selection that omits the library crates

### Requirement: DesignCraft rewrites patch-table git pins

DesignCraft `src_prepare` SHALL rewrite every one-line `[patch.*]` git pin whose crate name and `rev` equal a `GIT_CRATES` entry to the Portage work directory plus that entry's directory, with `%commit%` replaced by that entry's commit.

#### Scenario: Hayro follows the pdfcraft checkout

- **WHEN** `GIT_CRATES` records `hayro` at commit `b5467d93a0ffaa5e5e6658bccdf8655a3ba689c9` with directory `pdfcraft-%commit%/vendor/hayro` and `[patch.crates-io]` pins `hayro` at that rev
- **THEN** `src_prepare` rewrites that line to the unpacked `pdfcraft-b5467d93a0ffaa5e5e6658bccdf8655a3ba689c9/vendor/hayro` path
- **AND** the `src_prepare` source does not contain that commit as a literal

#### Scenario: Winit follows its checkout

- **WHEN** `GIT_CRATES` records `winit` at commit `3d51077fd1a966f84df9ef287839dc84fd5b4ca7` and `[patch.crates-io]` pins `winit` at that rev on a URL that ends in `.git`
- **THEN** `src_prepare` rewrites that line to the unpacked `winit-3d51077fd1a966f84df9ef287839dc84fd5b4ca7` path

#### Scenario: Repeated patch lines

- **WHEN** more than one `[patch.*]` line names the same crate at the `GIT_CRATES` commit
- **THEN** `src_prepare` rewrites every such line to that entry's unpacked path

### Requirement: DesignCraft rejects an unresolvable patch pin

DesignCraft `src_prepare` SHALL die before `src_compile` when a one-line `[patch.*]` git pin has no `GIT_CRATES` entry for that crate name and `rev`, or the rewritten checkout has no `Cargo.toml`.

#### Scenario: Missing GIT_CRATES entry

- **WHEN** a one-line `[patch.*]` git pin names a crate and rev that `GIT_CRATES` does not record
- **THEN** `src_prepare` dies
- **AND** the build does not continue into `src_compile`

#### Scenario: Missing checkout

- **WHEN** a patch pin matches a `GIT_CRATES` entry and that entry's unpacked directory has no `Cargo.toml`
- **THEN** `src_prepare` dies
- **AND** the build does not continue into `src_compile`

### Requirement: DesignCraft keeps direct git dependencies

DesignCraft `src_prepare` SHALL leave workspace git dependencies that sit outside `[patch.*]` unchanged.

#### Scenario: Craft-libs pins stay git dependencies

- **WHEN** `src_prepare` runs on a manifest whose `[workspace.dependencies]` pins `craft-print` and `craft-ui` by git rev and whose `[patch.crates-io]` pins `hayro` and `winit` by git rev
- **THEN** the `craft-print` and `craft-ui` lines stay git dependencies
- **AND** the `hayro` and `winit` lines become path dependencies
