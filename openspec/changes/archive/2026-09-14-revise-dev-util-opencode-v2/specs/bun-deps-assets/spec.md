## ADDED Requirements

### Requirement: Compile-pin ebuild invokes bun-exact after apply rewrite

When applying overlay ebuild changes for a planned PV of a compile-pin Bun package, the program SHALL rewrite the ebuild body so compile (and test, when present) invocations of a versioned `bun-<X.Y.Z>` command become `bun-<exact>`, where `<exact>` is the probed exact pin for that PV. The rewrite SHALL keep `BDEPEND` as `~dev-lang/bun-bin-<exact>` as already required. Unversioned `bun` in comments MAY be left unchanged. The program SHALL NOT invent a compile cwd or `build.ts` path.

#### Scenario: Pin bump rewrites compile invocation

- **WHEN** the donor opencode ebuild compiles with `bun-1.3.14` and the planned exact pin is `1.4.2`
- **THEN** after overlay rewrite `src_compile` invokes `bun-1.4.2`
- **AND** `BDEPEND` contains `~dev-lang/bun-bin-1.4.2`

#### Scenario: Test phase uses the same versioned bun

- **WHEN** the donor opencode ebuild has `src_test` that invokes `bun test` or `bun-<old> test` and the planned exact pin is `1.4.2`
- **THEN** after overlay rewrite `src_test` invokes `bun-1.4.2 test` (not unversioned `bun`)

### Requirement: Clone-time compile cwd and build.ts guard

For `dev-util/opencode` full-path materialization, after cloning the GitHub tag and before overlay write, the program SHALL parse the compile working directory from the donor ebuild (`cd` in `src_compile`) and SHALL hard-fail that PV if that directory does not exist in the clone or if `script/build.ts` is missing under that directory. The error SHALL name the missing path and the PV. The program SHALL NOT rewrite the compile cwd to a guessed replacement.

#### Scenario: Missing packages/opencode hard-fails

- **WHEN** the donor ebuild `cd`s to `packages/opencode` and the cloned tag has no `packages/opencode` directory
- **THEN** materialize/apply hard-fails before overlay commit
- **AND** the error names `packages/opencode`

#### Scenario: Missing build.ts hard-fails

- **WHEN** the donor ebuild compile cwd exists but `script/build.ts` is absent under that cwd
- **THEN** materialize/apply hard-fails before overlay commit

#### Scenario: Matching cwd proceeds

- **WHEN** the donor ebuild `cd`s to `packages/cli` and the clone contains `packages/cli/script/build.ts`
- **THEN** this guard does not hard-fail

## MODIFIED Requirements

### Requirement: Compile-pin Bun packages use exact bun-bin BDEPEND

A **compile-pin** Bun package is a `DepsAndAssets Bun` package whose overlay ebuild compiles a standalone Bun binary (`build.ts --compile` / `bun --compile`). `dev-util/opencode` SHALL be compile-pin (InstallTree packaging). When applying overlay ebuild changes for a planned PV of a compile-pin package, the program SHALL ensure `BDEPEND` contains `~dev-lang/bun-bin-<exact>` where `<exact>` is the probed exact pin for that PV (any Portage revision of that PV; `=` does not match `-rN`). The overlay ebuild contract SHALL invoke `bun-<exact>` (not unversioned `bun`) for that compile. The program SHALL NOT inject bun-bin into `RDEPEND` solely because the package is compile-pin.

#### Scenario: Opencode exact BDEPEND

- **WHEN** the opencode probe exact pin for a planned PV is `1.4.2`
- **THEN** after overlay rewrite `BDEPEND` contains `~dev-lang/bun-bin-1.4.2`

#### Scenario: Opencode compile uses versioned bun

- **WHEN** `src_compile` runs for `dev-util/opencode` whose exact pin is `1.4.2`
- **THEN** the compile invokes `bun-1.4.2` with `build.ts --single --skip-install` (and optional `--skip-web-ui` when `-webui`)

### Requirement: Opencode enabled end-to-end

`dev-util/opencode` SHALL use runtime lanes against overlay `dev-lang/bun-bin`, GitHub candidates under the shared candidate rule, Bun requirement probe (including `packageManager` fallback), deps-only assets publish/reuse, and overlay apply as specified for `DepsAndAssets Bun`. The package SHALL NOT soft-skip solely because deps assets are required. The hardcoded policy source SHALL be GitHub `anomalyco/opencode` with tag prefix `v`. The deps distfile for opencode SHALL use **InstallTree** packaging (not BunCache-only) so Portage compile does not require registry or GitHub network access. The program SHALL NOT require a models JSON companion distfile for opencode.

#### Scenario: No longer unsupported

- **WHEN** policy is resolved and apply runs for an outdated `dev-util/opencode`
- **THEN** the program does not soft-skip with reason unsupported deps assets

#### Scenario: Policy source and technique

- **WHEN** policy is resolved for `dev-util/opencode`
- **THEN** the source is GitHub `anomalyco/opencode` with prefix `v` and the technique is `DepsAndAssets Bun`

#### Scenario: InstallTree deps packaging

- **WHEN** full-path materialize succeeds for `dev-util/opencode` at a PV
- **THEN** the published `{pn}-{pv}-deps.tar.xz` contains a repo-relative install tree with `node_modules` (not only a top-level `bun-cache/` directory)

#### Scenario: No models companion required

- **WHEN** full-path materialize succeeds for `dev-util/opencode` at a PV
- **THEN** the program does not fetch models.dev
- **AND** the published release is not required to contain `{pn}-{pv}-models.json`

### Requirement: InstallTree packaging for opencode deps distfile

For `dev-util/opencode` full-path materialization of PV, after a successful image Bun gate and clone of the GitHub tag, the program SHALL run `bun install --frozen-lockfile` (network allowed during materialize) in the clone **inside the materialize container**, then create `{pn}-{pv}-deps.tar.xz` whose members are the **install tree** rooted at the repository root: all `node_modules` directories (and any additional workspace install artifacts required to build with `build.ts --skip-install`) with paths relative to that root. The tarball SHALL NOT be defined solely as a top-level `bun-cache/` directory. Packaging SHALL use the hermetic tar/xz rules specified by `hermetic-asset-materialize` (`XZ_OPT=-T1 -9e`) and SHALL verify the final deps path is an xz-compressed stream (hard-fail if not). Failure of install or packaging SHALL hard-fail the PV before assets publish.

#### Scenario: Deps basename unchanged

- **WHEN** InstallTree packaging succeeds for PN `opencode` at PV `2.0.3`
- **THEN** the output file is still named `opencode-2.0.3-deps.tar.xz`

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

The overlay ebuild contract for `dev-util/opencode` SHALL unpack the InstallTree deps tarball onto the source tree (`${S}`) and SHALL NOT run `bun install` (or equivalent registry install) during Portage phases that run under `network-sandbox`. Compile SHALL `cd` to `packages/cli` and SHALL use the preinstalled tree with `bun-<exact> --bun ./script/build.ts --single --skip-install` (and optional `--skip-web-ui` when `-webui`), where `<exact>` is the compile-pin bun-bin PV. Compile SHALL export `OPENCODE_VERSION` to the package PV, `OPENCODE_CHANNEL=prod`, and `NODE_OPTIONS=--max-old-space-size=4096`. Compile MAY set `OPENCODE_DISABLE_MODELS_FETCH=1` for the Portage phase. Compile SHALL NOT require `MODELS_DEV_API_JSON` or a models distfile. The program’s published deps asset and ebuild contract together SHALL make emerge succeed without compile-time access to npm registry or GitHub for dependency resolution.

#### Scenario: No bun install in compile

- **WHEN** an operator builds `dev-util/opencode` under FEATURES including `network-sandbox`
- **THEN** the ebuild does not invoke `bun install` to resolve dependencies from the network

#### Scenario: Build uses skip-install

- **WHEN** `src_compile` runs for opencode with `+webui` and exact pin `1.4.2`
- **THEN** the compile `cd`s to `packages/cli` and invokes `bun-1.4.2` with `build.ts --single --skip-install` against the unpacked install tree

#### Scenario: Skip web UI flag

- **WHEN** `src_compile` runs for opencode with `-webui` and exact pin `1.4.2`
- **THEN** the compile passes `--skip-web-ui` (not `--skip-embed-web-ui`)

### Requirement: Opencode Portage install preserves Bun-compiled binary and sandbox-safe completions

The overlay ebuild contract for `dev-util/opencode` SHALL install the Bun-compiled `opencode` binary from `packages/cli/dist/cli-*/bin/opencode` without ELF strip that corrupts the embed payload. The ebuild SHALL declare `RESTRICT="strip"` (or an equivalent Portage mechanism that prevents stripping that binary), merged with the test-gate token. The installed `/usr/bin/opencode` SHALL be a wrapper that exports `OPENCODE_DISABLE_AUTOUPDATE=1` and execs the compiled ELF; the wrapper SHALL NOT export `OPENCODE_DISABLE_MODELS_FETCH`. When generating optional shell completions by executing the installed binary under Portage `sandbox`, the ebuild SHALL allow the binary’s write to Linux ftrace’s trace marker (for example `addwrite /sys/kernel/debug/tracing` before running `opencode --completions`) so install does not fail with a sandbox access violation. Completions SHALL be generated with `opencode --completions bash`, `opencode --completions zsh`, and `opencode --completions fish` when the corresponding IUSE flags are enabled (`bash-completion`, `zsh-completion`, `fish-completion`). After a successful install, `opencode --version` SHALL report the package PV (from `OPENCODE_VERSION` / compile-time define), not the host Bun toolchain version alone.

#### Scenario: No strip on bun-compiled binary

- **WHEN** the opencode ebuild is installed under default Portage FEATURES that would otherwise strip ELF files
- **THEN** the installed compiled ELF is not stripped in a way that reduces it to bare Bun behavior

#### Scenario: Version reports package PV

- **WHEN** an operator runs `opencode --version` after a successful emerge of `dev-util/opencode` at PV `2.0.3`
- **THEN** the output contains `2.0.3` (not solely the host `bun --version` string)

#### Scenario: Completions under sandbox

- **WHEN** `src_install` generates bash, zsh, or fish completions by running `opencode --completions` under FEATURES including `sandbox`
- **THEN** install does not fail with an ACCESS DENIED write to `/sys/kernel/debug/tracing/trace_marker`

#### Scenario: Autoupdate disabled at runtime

- **WHEN** an operator runs the installed `/usr/bin/opencode` TUI or background service
- **THEN** `OPENCODE_DISABLE_AUTOUPDATE` is set in the process environment
- **AND** `OPENCODE_DISABLE_MODELS_FETCH` is not forced by the wrapper

## REMOVED Requirements

### Requirement: Models companion distfile for opencode

**Reason**: OpenCode 2.x bundles a models catalog snapshot in the source tree (`packages/core` snapshot). Compile does not read `MODELS_DEV_API_JSON`. Runtime may fetch `https://models.opencode.ai` unless the user disables it.

**Migration**: Drop models from opencode `SRC_URI`, Adequacy extras, and materialize companion fetch. Reuse and publish deps-only. Leave any already-uploaded `{pn}-{pv}-models.json` GitHub assets unused; do not require an assets `-r1`.
