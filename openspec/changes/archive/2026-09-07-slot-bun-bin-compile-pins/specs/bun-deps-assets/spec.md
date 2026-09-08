## ADDED Requirements

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

## MODIFIED Requirements

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

### Requirement: Opencode Portage compile is offline for dependency install

The overlay ebuild contract for `dev-util/opencode` SHALL unpack the InstallTree deps tarball onto the source tree (`${S}`) and SHALL NOT run `bun install` (or equivalent registry install) during Portage phases that run under `network-sandbox`. Compile SHALL use the preinstalled tree with `bun-<exact> --bun ./script/build.ts --single --skip-install` (and optional `--skip-embed-web-ui` when `-webui`), where `<exact>` is the compile-pin bun-bin PV. Models snapshot SHALL continue via `MODELS_DEV_API_JSON` pointing at the models distfile in DISTDIR. The program’s published assets and ebuild contract together SHALL make emerge succeed without compile-time access to npm registry or GitHub for dependency resolution.

#### Scenario: No bun install in compile

- **WHEN** an operator builds `dev-util/opencode` under FEATURES including `network-sandbox`
- **THEN** the ebuild does not invoke `bun install` to resolve dependencies from the network

#### Scenario: Build uses skip-install

- **WHEN** `src_compile` runs for opencode with `+webui` and exact pin `1.3.14`
- **THEN** the compile invokes `bun-1.3.14` with `build.ts --single --skip-install` against the unpacked install tree

## REMOVED Requirements

### Requirement: bun-bin BDEPEND greater-or-equal

**Reason**: Floor consumers now require `:0` on the atom, and compile-pin packages use `=dev-lang/bun-bin-<exact>` instead of a greater-or-equal floor.

**Migration**: Use compile-pin exact BDEPEND for opencode and slot-zero floor atoms for other Bun packages as specified by the added BDEPEND requirements.
