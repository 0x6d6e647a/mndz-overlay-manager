## Purpose

Bun deps packaging from GitHub tag (BunCache or InstallTree), Bun requirement probing (`engines.bun` or `packageManager` fallback, minimum vs compile-pin exact), bun-bin slot/install contract and BDEPEND atoms, overlay bun-bin ceilings, image Bun gate, and enablement of `dev-util/ralph-tui` and `dev-util/opencode` under `DepsAndAssets Bun`.

## Requirements

### Requirement: Bun cache tarball from GitHub tag

For `DepsAndAssets Bun` full-path materialization of PV for packages that use **BunCache** packaging (including `dev-util/ralph-tui`), the program SHALL: (1) clone the package’s GitHub source into the unit `work/` directory under the product temporary workspace defined by `temp-workspace` and check out the tag formed by the source tag prefix plus that PV; (2) require a `bun.lock` at the repository root and hard-fail if missing; (3) run `bun install --frozen-lockfile --cache-dir <bun-cache-path>` with the cache directory under the unit workspace so the cache can be packaged; (4) rewrite any absolute symbolic links under `bun-cache/` to relative targets that exist in that tree, as specified by `hermetic-asset-materialize`, and hard-fail if any absolute link remains; (5) create `{pn}-{pv}-deps.tar.xz` under the unit `out/` whose top-level entry is `bun-cache/`, packing with the hermetic tar/xz rules specified by `hermetic-asset-materialize`; (6) after writing the final deps tarball path, verify that the file is an xz-compressed stream and hard-fail if it is plain tar or otherwise not xz. Full-path clone, `bun install`, rewrite, and pack SHALL run in the materialize container. The program SHALL implement this in Haskell orchestration and SHALL NOT invoke overlay Python helper scripts. Unit temporary trees SHALL follow the `temp-workspace` lifecycle (delete on success or soft-skip; retain on hard-fail with path in the error).

#### Scenario: Tarball layout for ralph-tui

- **WHEN** bun cache construction succeeds for PN `ralph-tui` at PV `0.12.0`
- **THEN** the output file is named `ralph-tui-0.12.0-deps.tar.xz` and unpacking yields a top-level `bun-cache` directory

#### Scenario: Missing lockfile hard-fails

- **WHEN** the checked-out tag has no `bun.lock` at the repository root
- **THEN** materialization hard-fails before assets publish

#### Scenario: Bun deps pack uses extreme multi-thread xz

- **WHEN** the manager packs a BunCache deps tarball
- **THEN** the pack process uses `XZ_OPT` containing `-T1` and `-9e` (single-thread extreme; hermetic-asset-materialize)

#### Scenario: Bun deps pack rejects non-xz body

- **WHEN** the final `{pn}-{pv}-deps.tar.xz` path is not an xz-compressed stream after pack
- **THEN** materialize hard-fails before assets publish treats the file as successful

#### Scenario: BunCache alias links are relative

- **WHEN** bun cache construction packs the deps tarball
- **THEN** every symlink member under `bun-cache/` has a relative target present in the archive

### Requirement: Bun source and technique pairing

Apply for `DepsAndAssets Bun` SHALL require `UpdateSource` to be `GitHub`. If the technique is `DepsAndAssets Bun` but the source is not `GitHub`, apply SHALL hard-fail without publishing assets.

#### Scenario: Wrong source type

- **WHEN** technique is `DepsAndAssets Bun` and source is `Npm`
- **THEN** apply hard-fails before materialization

### Requirement: Overlay bun-bin slot and install contract

Overlay `dev-lang/bun-bin` SHALL use one ebuild template for all non-live PVs. The **newest** non-live PV SHALL have `SLOT="0"` and SHALL install `/usr/bin/bun-${PV}` plus unversioned `/usr/bin/bun` and `/usr/bin/bunx` symlinks to that binary, and SHALL install shell completions under the unversioned name `bun` when those IUSE flags are enabled. Every **kept compile-pin** PV that is not the newest SHALL have `SLOT="${PV}"` and SHALL install **only** `/usr/bin/bun-${PV}` (no unversioned `bun`, no `bunx`, no completions). Debug USE SHALL still produce a `bun-${PV}` path from whichever binary that USE built. When a compile-pin PV **is** the newest, a single `SLOT="0"` ebuild SHALL satisfy both roles (`bun-${PV}` exists and unversioned `bun` points at it).

#### Scenario: Latest owns unversioned bun

- **WHEN** overlay bun-bin newest non-live PV is `1.4.2` with `SLOT="0"`
- **THEN** the installed files include `/usr/bin/bun-1.4.2`, `/usr/bin/bun` → `bun-1.4.2`, and `/usr/bin/bunx` → `bun-1.4.2`

#### Scenario: Pin slot is versioned only

- **WHEN** overlay bun-bin also has kept pin PV `1.3.14` with `SLOT="1.3.14"`
- **THEN** that slot installs `/usr/bin/bun-1.3.14` and does not install `/usr/bin/bun`, `/usr/bin/bunx`, or completions named `bun`

#### Scenario: Pin equals latest is one ebuild

- **WHEN** the only compile-pin PV equals the newest bun-bin PV `1.4.2`
- **THEN** overlay has a single `bun-bin-1.4.2` ebuild with `SLOT="0"`
- **AND** `/usr/bin/bun-1.4.2` exists so compile-pin packages can invoke that name

### Requirement: Compile-pin Bun packages use exact bun-bin BDEPEND

A **compile-pin** Bun package is a `DepsAndAssets Bun` package whose overlay ebuild compiles a standalone Bun binary (`build.ts --compile` / `bun --compile`). `dev-util/opencode` SHALL be compile-pin (InstallTree packaging). When applying overlay ebuild changes for a planned PV of a compile-pin package, the program SHALL ensure `BDEPEND` contains `=dev-lang/bun-bin-<exact>` where `<exact>` is the probed exact pin for that PV. The overlay ebuild contract SHALL invoke `bun-<exact>` (not unversioned `bun`) for that compile. The program SHALL NOT inject bun-bin into `RDEPEND` solely because the package is compile-pin.

#### Scenario: Opencode exact BDEPEND

- **WHEN** the opencode probe exact pin for a planned PV is `1.3.14`
- **THEN** after overlay rewrite `BDEPEND` contains `=dev-lang/bun-bin-1.3.14`

#### Scenario: Opencode compile uses versioned bun

- **WHEN** `src_compile` runs for `dev-util/opencode` whose exact pin is `1.3.14`
- **THEN** the compile invokes `bun-1.3.14` with `build.ts --single --skip-install` (and optional `--skip-embed-web-ui` when `-webui`)

### Requirement: Floor Bun packages use slot-zero bun-bin atoms

A Bun package that is not compile-pin SHALL use a greater-or-equal bun-bin atom slot-qualified to `0`: `>=dev-lang/bun-bin-<minimum>:0` where `<minimum>` is the probed Bun minimum for that PV. When the ebuild already declares bun-bin in `RDEPEND` (for example `RDEPEND="${BDEPEND}"`), that runtime atom SHALL use the same `:0` floor form so a pin slot without `/usr/bin/bun` cannot satisfy it. The program SHALL insert or replace the `dev-lang/bun-bin` atom accordingly and SHALL NOT remove unrelated dependency atoms.

#### Scenario: Ralph floor is slot zero

- **WHEN** ralph-tui probe minimum is `1.3.6` and the package is not compile-pin
- **THEN** after overlay rewrite `BDEPEND` contains `>=dev-lang/bun-bin-1.3.6:0`

#### Scenario: Ralph RDEPEND cannot be satisfied by a pin slot alone

- **WHEN** ralph-tui has `RDEPEND="${BDEPEND}"` with `>=dev-lang/bun-bin-1.3.6:0` and overlay has pin `1.3.14:1.3.14` plus latest `1.4.2:0`
- **THEN** the runtime atom is satisfied by `1.4.2:0` and is not treated as satisfied by the pin slot alone

### Requirement: engines.bun requirement probe

For each candidate PV used in bun runtime-lane planning or BDEPEND alignment, the program SHALL obtain a Bun **minimum** and, when the package is compile-pin, an **exact pin**, from the package’s root `package.json` at the corresponding GitHub tag (or equivalent fetch).

Minimum (all Bun packages): (1) if `engines.bun` is present and parseable, use that requirement; (2) else if `packageManager` matches `bun@X.Y.Z` (optional leading `v`; optional build metadata after `X.Y.Z` ignored), use `X.Y.Z`; (3) else hard-fail planning for that candidate with an error that identifies the parse failure. For `engines.bun`, parse minimum forms: bare `X.Y.Z`, optional leading `v`, or `>=X.Y.Z`. Complex ranges (`^`, `||`, `<`, `*`) SHALL be unparseable. When both `engines.bun` and `packageManager` are present and `engines.bun` is parseable, `engines.bun` SHALL win as the **minimum**.

Exact pin (compile-pin packages only): if `packageManager` matches `bun@X.Y.Z` (same parsing as above), that `X.Y.Z` is the exact pin even when `engines.bun` supplied a different minimum; else if `engines.bun` is a **bare** `X.Y.Z` (no range operator), that value is the exact pin; else hard-fail that compile-pin candidate. Runtime-lane ceilings and the materialize-image Bun gate SHALL continue to use the **minimum**, not the exact pin.

#### Scenario: ralph-tui style engines

- **WHEN** `package.json` has `"engines": { "bun": ">=1.3.6" }`
- **THEN** the required bun **minimum** used for ceilings, image gate, and floor BDEPEND is `1.3.6`

#### Scenario: packageManager fallback for opencode

- **WHEN** `package.json` omits parseable `engines.bun` and has `"packageManager": "bun@1.3.14"`
- **THEN** the required bun minimum is `1.3.14`
- **AND** for compile-pin opencode the exact pin is `1.3.14`

#### Scenario: engines.bun wins over packageManager

- **WHEN** `package.json` has `"engines": { "bun": ">=1.2.0" }` and `"packageManager": "bun@1.3.14"`
- **THEN** the required bun **minimum** is `1.2.0`
- **AND** for a compile-pin package the exact pin is `1.3.14`

#### Scenario: Missing both hard-fails plan

- **WHEN** a required candidate’s `package.json` omits parseable `engines.bun` and omits a parseable `packageManager` `bun@X.Y.Z`
- **THEN** package planning hard-fails

### Requirement: Host Bun gate on full path

After determining the Bun **minimum** for a PV on the full materialize path, the program SHALL compare the materialize-image `bun` version to that minimum. If the image is strictly older, the program SHALL hard-fail that PV before `bun install` and SHALL NOT publish assets or mutate the overlay for that attempt. The reuse path SHALL NOT apply this gate. The program SHALL NOT require a host `bun` binary for this gate.

#### Scenario: Host too old

- **WHEN** engines require `1.3.6` and the materialize image Bun is older
- **THEN** full-path materialize hard-fails without publishing assets

### Requirement: Overlay bun-bin ceilings

Bun runtime-lane ceilings SHALL be read from `{overlay-path}/dev-lang/bun-bin` non-live ebuilds. Because overlay packages conventionally use tilde KEYWORDS only, plain ceilings MAY be absent so that only tilde lanes produce targets; KEYWORDS assembly SHALL still follow runtime-lanes rules.

#### Scenario: Tilde-only bun-bin

- **WHEN** bun-bin ebuilds declare only `~amd64` and `~arm64`
- **THEN** planned package KEYWORDS for a single collapsed PV may be `~amd64 ~arm64` without bare arches

### Requirement: ralph-tui enabled end-to-end

`dev-util/ralph-tui` SHALL use runtime lanes against overlay `dev-lang/bun-bin`, GitHub candidates under the shared candidate rule, deps asset publish/reuse, and overlay apply as specified for `DepsAndAssets Bun`. The package SHALL NOT soft-skip solely because deps assets are required.

#### Scenario: No longer unsupported

- **WHEN** policy is resolved and apply runs for an outdated `dev-util/ralph-tui`
- **THEN** the program does not soft-skip with reason unsupported deps assets

### Requirement: Models companion distfile for opencode

For `dev-util/opencode` full-path materialization of PV, after (or as part of) Bun deps tarball construction, the program SHALL fetch `https://models.dev/api.json` and write the response body to a distfile named `{pn}-{pv}-models.json` (overlay PN and PV without revision). Fetch or write failure SHALL hard-fail that PV before assets publish. The models distfile SHALL be published and reused together with the deps tarball as specified by assets-publish multi-asset rules. The program SHALL NOT require Portage emerge to fetch models.dev.

#### Scenario: Models basename for opencode

- **WHEN** models snapshot construction succeeds for PN `opencode` at PV `1.18.4`
- **THEN** the output file is named `opencode-1.18.4-models.json`

#### Scenario: Models fetch failure hard-fails

- **WHEN** `https://models.dev/api.json` cannot be fetched during full materialize for opencode
- **THEN** that PV hard-fails without publishing a release that omits models

### Requirement: Opencode enabled end-to-end

`dev-util/opencode` SHALL use runtime lanes against overlay `dev-lang/bun-bin`, GitHub candidates under the shared candidate rule, Bun requirement probe (including `packageManager` fallback), multi-asset deps+models publish/reuse, and overlay apply as specified for `DepsAndAssets Bun`. The package SHALL NOT soft-skip solely because deps or models assets are required. The hardcoded policy source SHALL be GitHub `anomalyco/opencode` with tag prefix `v`. The deps distfile for opencode SHALL use **InstallTree** packaging (not BunCache-only) so Portage compile does not require registry or GitHub network access.

#### Scenario: No longer unsupported

- **WHEN** policy is resolved and apply runs for an outdated `dev-util/opencode`
- **THEN** the program does not soft-skip with reason unsupported deps assets

#### Scenario: Policy source and technique

- **WHEN** policy is resolved for `dev-util/opencode`
- **THEN** the source is GitHub `anomalyco/opencode` with prefix `v` and the technique is `DepsAndAssets Bun`

#### Scenario: InstallTree deps packaging

- **WHEN** full-path materialize succeeds for `dev-util/opencode` at a PV
- **THEN** the published `{pn}-{pv}-deps.tar.xz` contains a repo-relative install tree with `node_modules` (not only a top-level `bun-cache/` directory)

### Requirement: InstallTree packaging for opencode deps distfile

For `dev-util/opencode` full-path materialization of PV, after a successful image Bun gate and clone of the GitHub tag, the program SHALL run `bun install --frozen-lockfile` (network allowed during materialize) in the clone **inside the materialize container**, then create `{pn}-{pv}-deps.tar.xz` whose members are the **install tree** rooted at the repository root: all `node_modules` directories (and any additional workspace install artifacts required to build with `build.ts --skip-install`) with paths relative to that root. The tarball SHALL NOT be defined solely as a top-level `bun-cache/` directory. Packaging SHALL use the hermetic tar/xz rules specified by `hermetic-asset-materialize` (`XZ_OPT=-T1 -9e`) and SHALL verify the final deps path is an xz-compressed stream (hard-fail if not). Failure of install or packaging SHALL hard-fail the PV before assets publish. The program SHALL still publish models JSON multi-asset rules for opencode. Models JSON fetch MAY run on the host after container pack.

#### Scenario: Deps basename unchanged

- **WHEN** InstallTree packaging succeeds for PN `opencode` at PV `1.18.5`
- **THEN** the output file is still named `opencode-1.18.5-deps.tar.xz`

#### Scenario: Install tree has node_modules

- **WHEN** the deps tarball is listed after InstallTree packaging for opencode
- **THEN** members include a `node_modules` path under the repository root layout

#### Scenario: Install failure hard-fails

- **WHEN** `bun install` fails during full materialize for opencode
- **THEN** the PV hard-fails without publishing a partial deps release

#### Scenario: InstallTree deps pack uses extreme multi-thread xz

- **WHEN** the manager packs an InstallTree deps tarball for opencode
- **THEN** the pack process uses `XZ_OPT` containing `-T1` and `-9e` (single-thread extreme; hermetic-asset-materialize)

### Requirement: Opencode Portage compile is offline for dependency install

The overlay ebuild contract for `dev-util/opencode` SHALL unpack the InstallTree deps tarball onto the source tree (`${S}`) and SHALL NOT run `bun install` (or equivalent registry install) during Portage phases that run under `network-sandbox`. Compile SHALL use the preinstalled tree with `bun-<exact> --bun ./script/build.ts --single --skip-install` (and optional `--skip-embed-web-ui` when `-webui`), where `<exact>` is the compile-pin bun-bin PV. Models snapshot SHALL continue via `MODELS_DEV_API_JSON` pointing at the models distfile in DISTDIR. The program’s published assets and ebuild contract together SHALL make emerge succeed without compile-time access to npm registry or GitHub for dependency resolution.

#### Scenario: No bun install in compile

- **WHEN** an operator builds `dev-util/opencode` under FEATURES including `network-sandbox`
- **THEN** the ebuild does not invoke `bun install` to resolve dependencies from the network

#### Scenario: Build uses skip-install

- **WHEN** `src_compile` runs for opencode with `+webui` and exact pin `1.3.14`
- **THEN** the compile invokes `bun-1.3.14` with `build.ts --single --skip-install` against the unpacked install tree

### Requirement: Opencode Portage install preserves Bun-compiled binary and sandbox-safe completions

The overlay ebuild contract for `dev-util/opencode` SHALL install the Bun-compiled `opencode` binary without ELF strip that corrupts the embed payload. The ebuild SHALL declare `RESTRICT="strip"` (or an equivalent Portage mechanism that prevents stripping that binary). When generating optional shell completions by executing the installed binary under Portage `sandbox`, the ebuild SHALL allow the binary’s write to Linux ftrace’s trace marker (for example `addwrite /sys/kernel/debug/tracing` before running `opencode completion`) so install does not fail with a sandbox access violation. After a successful install, `opencode --version` SHALL report the package PV (from `OPENCODE_VERSION` / compile-time define), not the host Bun toolchain version alone.

#### Scenario: No strip on bun-compiled binary

- **WHEN** the opencode ebuild is installed under default Portage FEATURES that would otherwise strip ELF files
- **THEN** the installed `/usr/bin/opencode` is not stripped in a way that reduces it to bare Bun behavior

#### Scenario: Version reports package PV

- **WHEN** an operator runs `opencode --version` after a successful emerge of `dev-util/opencode` at PV `1.18.5`
- **THEN** the output is `1.18.5` (not solely the host `bun --version` string)

#### Scenario: Completions under sandbox

- **WHEN** `src_install` generates bash or zsh completions by running the installed `opencode completion` under FEATURES including `sandbox`
- **THEN** install does not fail with an ACCESS DENIED write to `/sys/kernel/debug/tracing/trace_marker`
