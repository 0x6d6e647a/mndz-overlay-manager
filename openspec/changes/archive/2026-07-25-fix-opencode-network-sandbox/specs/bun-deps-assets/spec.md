## MODIFIED Requirements

### Requirement: Bun cache tarball from GitHub tag

For `DepsAndAssets Bun` full-path materialization of PV for packages that use **BunCache** packaging (including `dev-util/ralph-tui`), the program SHALL: (1) clone the package’s GitHub source into a temporary directory and check out the tag formed by the source tag prefix plus that PV; (2) require a `bun.lock` at the repository root and hard-fail if missing; (3) run `bun install --frozen-lockfile --cache-dir <bun-cache-path>` with the cache directory outside or beside the clone as needed so the cache can be packaged; (4) create `{pn}-{pv}-deps.tar.xz` whose top-level entry is `bun-cache/`, using xz compression suitable for large artifacts (including multi-threaded xz settings equivalent to `XZ_OPT=-T0 -9`). The program SHALL implement this in Haskell orchestration and SHALL NOT invoke overlay Python helper scripts. The temporary clone SHALL be removed when the PV attempt finishes.

#### Scenario: Tarball layout for ralph-tui

- **WHEN** bun cache construction succeeds for PN `ralph-tui` at PV `0.12.0`
- **THEN** the output file is named `ralph-tui-0.12.0-deps.tar.xz` and unpacking yields a top-level `bun-cache` directory

#### Scenario: Missing lockfile hard-fails

- **WHEN** the checked-out tag has no `bun.lock` at the repository root
- **THEN** materialization hard-fails before assets publish

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

## ADDED Requirements

### Requirement: InstallTree packaging for opencode deps distfile

For `dev-util/opencode` full-path materialization of PV, after a successful host Bun gate and clone of the GitHub tag, the program SHALL run `bun install --frozen-lockfile` (network allowed on the manager host) in the clone, then create `{pn}-{pv}-deps.tar.xz` whose members are the **install tree** rooted at the repository root: all `node_modules` directories (and any additional workspace install artifacts required to build with `build.ts --skip-install`) with paths relative to that root. The tarball SHALL NOT be defined solely as a top-level `bun-cache/` directory. Failure of install or packaging SHALL hard-fail the PV before assets publish. The program SHALL still publish models JSON multi-asset rules for opencode.

#### Scenario: Deps basename unchanged

- **WHEN** InstallTree packaging succeeds for PN `opencode` at PV `1.18.5`
- **THEN** the output file is still named `opencode-1.18.5-deps.tar.xz`

#### Scenario: Install tree has node_modules

- **WHEN** the deps tarball is listed after InstallTree packaging for opencode
- **THEN** members include a `node_modules` path under the repository root layout

#### Scenario: Install failure hard-fails

- **WHEN** `bun install` fails during full materialize for opencode
- **THEN** the PV hard-fails without publishing a partial deps release

### Requirement: Opencode Portage compile is offline for dependency install

The overlay ebuild contract for `dev-util/opencode` SHALL unpack the InstallTree deps tarball onto the source tree (`${S}`) and SHALL NOT run `bun install` (or equivalent registry install) during Portage phases that run under `network-sandbox`. Compile SHALL use the preinstalled tree with `bun --bun ./script/build.ts --single --skip-install` (and optional `--skip-embed-web-ui` when `-webui`). Models snapshot SHALL continue via `MODELS_DEV_API_JSON` pointing at the models distfile in DISTDIR. The program’s published assets and ebuild contract together SHALL make emerge succeed without compile-time access to npm registry or GitHub for dependency resolution.

#### Scenario: No bun install in compile

- **WHEN** an operator builds `dev-util/opencode` under FEATURES including `network-sandbox`
- **THEN** the ebuild does not invoke `bun install` to resolve dependencies from the network

#### Scenario: Build uses skip-install

- **WHEN** `src_compile` runs for opencode with `+webui`
- **THEN** the compile invokes `build.ts` with `--single --skip-install` against the unpacked install tree

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
