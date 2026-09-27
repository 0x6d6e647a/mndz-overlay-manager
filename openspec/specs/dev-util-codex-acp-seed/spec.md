# dev-util-codex-acp-seed Specification

## Purpose

Product truth for the manually seeded `dev-util/codex-acp` overlay package (frozen PV 1.13.0): scoped npm packaging, offline deps assets, default-off `bundled-codex` (system `dev-util/codex` unless the npm CLI is requested), donor node floor, `KEYWORDS`, offline `src_test`, and operator smoke acceptance. This is overlay/seed truth, distinct from `dev-util/codex`, and not mndz-overlay-manager runtime behavior.

## Requirements

### Requirement: Package identity and version pin

The seeded package SHALL be `dev-util/codex-acp` at Portage version `1.13.0`, corresponding to npm package `@agentclientprotocol/codex-acp` version `1.13.0` (GitHub `agentclientprotocol/codex-acp` tag `v1.13.0`). The seed SHALL use `1.13.0` and SHALL NOT use `1.13.1` or any `preview` dist-tag version for the initial ebuild. The live ebuild filename SHALL be `codex-acp-1.13.0.ebuild` without a `-r0` suffix. Content-only fixes SHALL use `-r1` or greater when a revision bump is required. This package SHALL remain distinct from overlay `dev-util/codex`.

#### Scenario: Filename and source

- **WHEN** the seed package is added to the overlay
- **THEN** the ebuild path is `dev-util/codex-acp/codex-acp-1.13.0.ebuild` (or `codex-acp-1.13.0-rN.ebuild` only if a content revision is required)
- **AND** the primary source archive is the npm registry tarball for `@agentclientprotocol/codex-acp@1.13.0`

### Requirement: Metadata description and license

The ebuild SHALL set `DESCRIPTION` to a short upstream-derived summary (ACP adapter for the Codex CLI), `HOMEPAGE` to `https://github.com/agentclientprotocol/codex-acp`, and `LICENSE` to `Apache-2.0`. `metadata.xml` SHALL declare GitHub remote-id `agentclientprotocol/codex-acp`.

#### Scenario: License and homepage

- **WHEN** the ebuild and metadata are inspected
- **THEN** the homepage is `https://github.com/agentclientprotocol/codex-acp`
- **AND** `LICENSE` is `Apache-2.0`
- **AND** `metadata.xml` declares remote-id type `github` with value `agentclientprotocol/codex-acp`

### Requirement: Scoped npm registry tarball as packaging source

The ebuild's primary `SRC_URI` SHALL fetch the npm registry tarball for `@agentclientprotocol/codex-acp`, parameterized by `${PV}`, and SHALL rename that distfile to `${P}.tgz`. The ebuild SHALL NOT fetch the GitHub source archive and SHALL NOT run a TypeScript build.

#### Scenario: Primary SRC_URI form

- **WHEN** the ebuild is written
- **THEN** it contains a `SRC_URI` entry of the form `https://registry.npmjs.org/@agentclientprotocol/codex-acp/-/codex-acp-${PV}.tgz -> ${P}.tgz`
- **AND** no `SRC_URI` entry references `github.com/agentclientprotocol/codex-acp/archive`

### Requirement: Offline deps assets publish

A deps tarball named `codex-acp-1.13.0-deps.tar.xz` SHALL be published to `mndz-overlay-assets` as release tag `codex-acp-1.13.0`, with `b3`, `sha256`, and `sha512` checksum sidecars committed under `dev-util/codex-acp/` in the assets repository and a GPG-signed assets commit. The tarball SHALL contain a top-level `npm-cache/` directory, SHALL omit `npm-cache/_logs/` and `npm-cache/_update-notifier*` members, and SHALL be an xz-compressed stream packed with the hermetic tar/xz rules. The seed materialization SHALL mirror the registry-only npm cache tarball steps of `npm-deps-assets` (`npm pack` of `@agentclientprotocol/codex-acp@1.13.0`, npm cache population with an empty userconfig) and SHALL run in the materialize image container. The cache SHALL include the linux-x64 optional package of `@openai/codex` that npm installs for this platform. The ebuild SHALL reference the release via a fully parameterized assets `SRC_URI` using `${PV}`.

#### Scenario: Assets URL form

- **WHEN** the ebuild is written
- **THEN** it contains a `SRC_URI` entry of the form `https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/codex-acp-${PV}/codex-acp-${PV}-deps.tar.xz`

#### Scenario: Tarball layout

- **WHEN** the seeded deps tarball is unpacked
- **THEN** it yields a top-level `npm-cache` directory
- **AND** it contains no `npm-cache/_logs/` members

#### Scenario: Sidecars and signing

- **WHEN** the assets release is published
- **THEN** `dev-util/codex-acp/codex-acp-1.13.0-deps.tar.xz.{b3,sha256,sha512}` exist in the assets worktree
- **AND** the assets commit adding them is GPG-signed

### Requirement: Node floor BDEPEND atom

The pinned npm version omits `engines.node`. The ebuild SHALL declare the build/runtime dependency atom `>=net-libs/nodejs-22[npm]`, with the `[npm]` USE dependency required. That atom is the donor floor npm planning preserves while upstream omits `engines.node`.

#### Scenario: Nodejs atom

- **WHEN** the ebuild is inspected
- **THEN** it contains the atom `>=net-libs/nodejs-22[npm]`
- **AND** that atom appears once, with a single `[npm]` USE dependency

### Requirement: KEYWORDS amd64 only

The seed ebuild SHALL set `KEYWORDS="-* ~amd64"`. It SHALL NOT keyword `arm`, `arm64`, `loong`, `ppc64`, `riscv`, `x86`, or `x64-macos`.

#### Scenario: Keyword set

- **WHEN** the ebuild is inspected
- **THEN** `KEYWORDS` is `-* ~amd64`

### Requirement: bundled-codex revision of the live PV

The live ebuild for installed PV `1.13.1` SHALL be `codex-acp-1.13.1-r1.ebuild`. The unrevised `codex-acp-1.13.1.ebuild` SHALL NOT remain the live file. `IUSE` SHALL include `bundled-codex` without a default-on `+` prefix. `metadata.xml` SHALL describe `bundled-codex` as installing the Codex CLI bundled in the npm package.

#### Scenario: Revision path

- **WHEN** the harness flag is published
- **THEN** the live ebuild path is `dev-util/codex-acp/codex-acp-1.13.1-r1.ebuild`
- **AND** `codex-acp-1.13.1.ebuild` is not a live ebuild

#### Scenario: Flag defaults off

- **WHEN** the ebuild `IUSE` is inspected
- **THEN** `bundled-codex` is present and is not prefixed with `+`

### Requirement: Installed command name

`src_install` SHALL install `/usr/bin/codex-acp` via an offline global npm install from the deps cache into `${ED}/usr`. The installed image SHALL NOT contain `/usr/bin/codex`.

When `bundled-codex` is disabled, that install SHALL pass `--omit=optional`, SHALL replace the npm bin with a wrapper that exports `CODEX_PATH=/usr/bin/codex` when the variable is unset and then executes the adapter entrypoint, and the ebuild SHALL declare an unversioned `dev-util/codex` atom on `RDEPEND` inside `!bundled-codex? ( )`.

When `bundled-codex` is enabled, that install SHALL NOT pass `--omit=optional`, SHALL leave the npm bin in place, and SHALL NOT declare a dependency on `dev-util/codex`.

#### Scenario: Bin name

- **WHEN** the package is emerged
- **THEN** `/usr/bin/codex-acp` exists
- **AND** this package's installed image does not contain `/usr/bin/codex`

#### Scenario: Default install uses the system Codex

- **WHEN** the package is emerged with `bundled-codex` disabled
- **THEN** `/usr/bin/codex-acp` is a wrapper that defaults `CODEX_PATH` to `/usr/bin/codex`
- **AND** the installed image does not contain `/usr/bin/codex` from this package
- **AND** `RDEPEND` includes `dev-util/codex` only in the `!bundled-codex?` group

#### Scenario: Flag on keeps the npm bin

- **WHEN** the package is emerged with `bundled-codex` enabled
- **THEN** `/usr/bin/codex-acp` is the npm-installed bin
- **AND** the ebuild does not depend on `dev-util/codex`

### Requirement: Prebuilt Codex CLI is not stripped

The ebuild SHALL set `QA_PREBUILT` on the nested prebuilt Codex ELF from the linux-x64 optional package of `@openai/codex`. The pattern SHALL match that ELF under `usr/lib*/node_modules/@agentclientprotocol/codex-acp/node_modules/` and SHALL NOT embed a Codex version. `QA_PREBUILT` SHALL remain set whether or not `bundled-codex` is enabled.

When `bundled-codex` is enabled, `src_install` SHALL call `dostrip -x` on that installed path and SHALL fail when the ELF is absent. When `bundled-codex` is disabled, `src_install` SHALL succeed without that ELF and SHALL NOT call `dostrip -x` on a missing path.

#### Scenario: QA_PREBUILT pattern

- **WHEN** the ebuild is inspected
- **THEN** `QA_PREBUILT` names the nested Codex ELF under `usr/lib*/node_modules/@agentclientprotocol/codex-acp/node_modules/`

#### Scenario: Missing ELF fails install

- **WHEN** `bundled-codex` is enabled and the offline install does not place the nested Codex ELF
- **THEN** `src_install` fails

#### Scenario: Flag on requires the ELF

- **WHEN** `bundled-codex` is enabled and the offline install does not place the nested Codex ELF
- **THEN** `src_install` fails

#### Scenario: Flag off allows a missing ELF

- **WHEN** `bundled-codex` is disabled and the offline install omits the nested Codex ELF
- **THEN** `src_install` succeeds

### Requirement: No completions surface

The ebuild SHALL NOT inherit `shell-completion` and SHALL NOT declare bash, zsh, or fish completion USE flags.

#### Scenario: No completion USE flags

- **WHEN** the ebuild is inspected
- **THEN** it does not declare `bash-completion`, `zsh-completion`, or `fish-completion` USE flags
- **AND** it does not inherit `shell-completion`
- **AND** `IUSE` contains `bundled-codex` and `test` and no completion flag

### Requirement: Offline src_test version smoke

The ebuild SHALL include `test` in `IUSE` and set `RESTRICT` to include `!test? ( test )`. `src_test` SHALL install the package into a temporary prefix from the offline deps cache, passing `--omit=optional` when `bundled-codex` is disabled, and SHALL run `codex-acp --version` there. The phase SHALL fail unless that command exits 0 and its stdout is `@agentclientprotocol/codex-acp` followed by a space and the package PV. The test phase SHALL NOT require network access and SHALL NOT treat `--help` or `-v` as the smoke command. The version check SHALL pass with `bundled-codex` disabled.

#### Scenario: Offline version smoke

- **WHEN** Portage runs `src_test` with network isolation for a live PV
- **THEN** the phase installs from the deps cache offline
- **AND** `codex-acp --version` exits 0 with stdout `@agentclientprotocol/codex-acp` plus that PV

#### Scenario: Default USE omits the optional CLI in src_test

- **WHEN** `src_test` runs with `bundled-codex` disabled
- **THEN** the temporary npm install passes `--omit=optional`
- **AND** `codex-acp --version` still exits 0 with the expected stdout

### Requirement: Operator smoke acceptance

After overlay and assets are published, the operator SHALL verify the seed by emerging `=dev-util/codex-acp-1.13.0` and running `codex-acp --version`. That command SHALL exit 0 and report `@agentclientprotocol/codex-acp 1.13.0`. This is the seed acceptance gate before the manager-driven bump to a newer upstream PV is attempted.

#### Scenario: Smoke command

- **WHEN** seed publish is complete
- **THEN** emerge of `=dev-util/codex-acp-1.13.0` succeeds
- **AND** `codex-acp --version` exits 0 and reports `@agentclientprotocol/codex-acp 1.13.0`
