# dev-util-claude-agent-acp-seed Specification

## Purpose

Product truth for the manually seeded `dev-util/claude-agent-acp` overlay package (frozen PV 0.81.1): scoped npm packaging, offline deps assets, default-off `bundled-claude` (gentoo `dev-util/claude-code` unless the SDK ELF is requested), default-off `external-claude` (operator-supplied `CLAUDE_CODE_EXECUTABLE` and no `dev-util/claude-code` dependency), node floor, `KEYWORDS`, offline `src_test`, and operator smoke acceptance. This is overlay/seed truth, not mndz-overlay-manager runtime behavior.

## Requirements

### Requirement: Package identity and version pin

The seeded package SHALL be `dev-util/claude-agent-acp` at Portage version `0.81.1`, corresponding to npm package `@agentclientprotocol/claude-agent-acp` version `0.81.1` (GitHub `agentclientprotocol/claude-agent-acp` tag `v0.81.1`). The seed SHALL use `0.81.1` and SHALL NOT use `0.81.2` or any `preview` dist-tag version for the initial ebuild. The live ebuild filename SHALL be `claude-agent-acp-0.81.1.ebuild` without a `-r0` suffix. Content-only fixes SHALL use `-r1` or greater when a revision bump is required.

#### Scenario: Filename and source

- **WHEN** the seed package is added to the overlay
- **THEN** the ebuild path is `dev-util/claude-agent-acp/claude-agent-acp-0.81.1.ebuild` (or `claude-agent-acp-0.81.1-rN.ebuild` only if a content revision is required)
- **AND** the primary source archive is the npm registry tarball for `@agentclientprotocol/claude-agent-acp@0.81.1`

### Requirement: Metadata description and license

The ebuild SHALL set `DESCRIPTION` to a short upstream-derived summary (ACP adapter for the Claude Agent SDK), `HOMEPAGE` to `https://github.com/agentclientprotocol/claude-agent-acp`, and `LICENSE` to `Apache-2.0`. `metadata.xml` SHALL declare GitHub remote-id `agentclientprotocol/claude-agent-acp`.

#### Scenario: License and homepage

- **WHEN** the ebuild and metadata are inspected
- **THEN** the homepage is `https://github.com/agentclientprotocol/claude-agent-acp`
- **AND** `LICENSE` is `Apache-2.0`
- **AND** `metadata.xml` declares remote-id type `github` with value `agentclientprotocol/claude-agent-acp`

### Requirement: Scoped npm registry tarball as packaging source

The ebuild's primary `SRC_URI` SHALL fetch the npm registry tarball for `@agentclientprotocol/claude-agent-acp`, parameterized by `${PV}`, and SHALL rename that distfile to `${P}.tgz`. The ebuild SHALL NOT fetch the GitHub source archive and SHALL NOT run a TypeScript build.

#### Scenario: Primary SRC_URI form

- **WHEN** the ebuild is written
- **THEN** it contains a `SRC_URI` entry of the form `https://registry.npmjs.org/@agentclientprotocol/claude-agent-acp/-/claude-agent-acp-${PV}.tgz -> ${P}.tgz`
- **AND** no `SRC_URI` entry references `github.com/agentclientprotocol/claude-agent-acp/archive`

### Requirement: Offline deps assets publish

A deps tarball named `claude-agent-acp-0.81.1-deps.tar.xz` SHALL be published to `mndz-overlay-assets` as release tag `claude-agent-acp-0.81.1`, with `b3`, `sha256`, and `sha512` checksum sidecars committed under `dev-util/claude-agent-acp/` in the assets repository and a GPG-signed assets commit. The tarball SHALL contain a top-level `npm-cache/` directory, SHALL omit `npm-cache/_logs/` and `npm-cache/_update-notifier*` members, and SHALL be an xz-compressed stream packed with the hermetic tar/xz rules. The seed materialization SHALL mirror the registry-only npm cache tarball steps of `npm-deps-assets` (`npm pack` of `@agentclientprotocol/claude-agent-acp@0.81.1`, npm cache population with an empty userconfig) and SHALL run in the materialize image container. The ebuild SHALL reference the release via a fully parameterized assets `SRC_URI` using `${PV}`.

#### Scenario: Assets URL form

- **WHEN** the ebuild is written
- **THEN** it contains a `SRC_URI` entry of the form `https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/claude-agent-acp-${PV}/claude-agent-acp-${PV}-deps.tar.xz`

#### Scenario: Tarball layout

- **WHEN** the seeded deps tarball is unpacked
- **THEN** it yields a top-level `npm-cache` directory
- **AND** it contains no `npm-cache/_logs/` members

#### Scenario: Sidecars and signing

- **WHEN** the assets release is published
- **THEN** `dev-util/claude-agent-acp/claude-agent-acp-0.81.1-deps.tar.xz.{b3,sha256,sha512}` exist in the assets worktree
- **AND** the assets commit adding them is GPG-signed

### Requirement: Node floor BDEPEND atom

The ebuild SHALL declare the build/runtime dependency atom `>=net-libs/nodejs-22[npm]`, matching the parsed minimum of the pinned version's `engines.node` value `>=22`, with the `[npm]` USE dependency required.

#### Scenario: Nodejs atom

- **WHEN** the ebuild is inspected
- **THEN** it contains the atom `>=net-libs/nodejs-22[npm]`
- **AND** that atom appears once, with a single `[npm]` USE dependency

### Requirement: KEYWORDS amd64 only

The seed ebuild SHALL set `KEYWORDS="-* ~amd64"`. It SHALL NOT keyword `arm`, `arm64`, `loong`, `ppc64`, `riscv`, `x86`, or `x64-macos`.

#### Scenario: Keyword set

- **WHEN** the ebuild is inspected
- **THEN** `KEYWORDS` is `-* ~amd64`

### Requirement: bundled-claude revision of the live PV

The live ebuild for installed PV `0.86.0` SHALL be `claude-agent-acp-0.86.0-r1.ebuild`. The unrevised `claude-agent-acp-0.86.0.ebuild` SHALL NOT remain the live file. `IUSE` SHALL include `bundled-claude` and `external-claude`, each without a default-on `+` prefix. `REQUIRED_USE` SHALL be `?? ( bundled-claude external-claude )`. `metadata.xml` SHALL describe `bundled-claude` as installing the Claude CLI bundled in the npm package, and SHALL describe `external-claude` as using a Claude Code executable supplied outside Portage via `CLAUDE_CODE_EXECUTABLE`.

#### Scenario: Revision path

- **WHEN** the external harness flag is published
- **THEN** the live ebuild path is `dev-util/claude-agent-acp/claude-agent-acp-0.86.0-r1.ebuild`
- **AND** `claude-agent-acp-0.86.0.ebuild` is not a live ebuild

#### Scenario: Flag defaults off

- **WHEN** the ebuild `IUSE` is inspected
- **THEN** `bundled-claude` is present and is not prefixed with `+`
- **AND** `external-claude` is present and is not prefixed with `+`

#### Scenario: At most one harness flag

- **WHEN** the ebuild `REQUIRED_USE` is inspected
- **THEN** it is `?? ( bundled-claude external-claude )`

#### Scenario: Both harness flags are rejected

- **WHEN** the package is emerged with `bundled-claude` and `external-claude` both enabled
- **THEN** Portage rejects the USE combination

### Requirement: Installed command name

`src_install` SHALL install `/usr/bin/claude-agent-acp` via an offline global npm install from the deps cache into `${ED}/usr`. This package's installed image SHALL NOT contain `/usr/bin/claude` or `/opt/bin/claude`.

When `bundled-claude` and `external-claude` are both disabled, that install SHALL pass `--omit=optional`, SHALL replace the npm bin with a wrapper that exports `CLAUDE_CODE_EXECUTABLE=/opt/bin/claude` when the variable is unset and then executes the adapter entrypoint, and the ebuild SHALL declare an unversioned `dev-util/claude-code` atom on `RDEPEND` inside `!bundled-claude? ( !external-claude? ( dev-util/claude-code ) )`.

When `bundled-claude` is enabled, that install SHALL NOT pass `--omit=optional`, SHALL leave the npm bin in place, and SHALL NOT declare a dependency on `dev-util/claude-code`.

When `external-claude` is enabled, that install SHALL pass `--omit=optional`, SHALL leave the npm bin in place, SHALL NOT install a wrapper, SHALL NOT export `CLAUDE_CODE_EXECUTABLE`, and SHALL NOT declare a dependency on `dev-util/claude-code`. The installed image SHALL NOT contain the nested Claude CLI.

#### Scenario: Bin name

- **WHEN** the package is emerged
- **THEN** `/usr/bin/claude-agent-acp` exists
- **AND** this package's installed image does not contain `/usr/bin/claude`

#### Scenario: Default install uses gentoo Claude Code

- **WHEN** the package is emerged with `bundled-claude` and `external-claude` both disabled
- **THEN** `/usr/bin/claude-agent-acp` is a wrapper that defaults `CLAUDE_CODE_EXECUTABLE` to `/opt/bin/claude`
- **AND** this package's installed image does not contain `/usr/bin/claude`
- **AND** `RDEPEND` includes `dev-util/claude-code` only inside `!bundled-claude? ( !external-claude? ( dev-util/claude-code ) )`

#### Scenario: Flag on keeps the npm bin

- **WHEN** the package is emerged with `bundled-claude` enabled
- **THEN** `/usr/bin/claude-agent-acp` is the npm-installed bin
- **AND** the ebuild does not depend on `dev-util/claude-code`

#### Scenario: External flag keeps the npm bin and drops the harness

- **WHEN** the package is emerged with `external-claude` enabled and `bundled-claude` disabled
- **THEN** `/usr/bin/claude-agent-acp` is the npm-installed bin
- **AND** that bin does not export `CLAUDE_CODE_EXECUTABLE`
- **AND** the installed image does not contain the nested Claude CLI
- **AND** the ebuild does not depend on `dev-util/claude-code`

### Requirement: Prebuilt Claude CLI is not stripped

The ebuild SHALL set `QA_PREBUILT` so Portage does not strip the nested glibc x86-64 Claude CLI installed by the optional dependency `@anthropic-ai/claude-agent-sdk-linux-x64`. The pattern SHALL cover `usr/lib*/node_modules/@agentclientprotocol/claude-agent-acp/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64/claude`. `QA_PREBUILT` SHALL remain set whether or not `bundled-claude` is enabled.

When `bundled-claude` is enabled, `src_install` SHALL call `dostrip -x` on that installed path and SHALL fail when the ELF is absent. When `bundled-claude` is disabled, `src_install` SHALL succeed without that ELF and SHALL NOT call `dostrip -x` on a missing path.

#### Scenario: QA_PREBUILT pattern

- **WHEN** the ebuild is inspected
- **THEN** `QA_PREBUILT` includes `usr/lib*/node_modules/@agentclientprotocol/claude-agent-acp/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64/claude`

#### Scenario: Flag on requires the ELF

- **WHEN** `bundled-claude` is enabled and the offline install does not place the nested Claude ELF
- **THEN** `src_install` fails

#### Scenario: Flag off allows a missing ELF

- **WHEN** `bundled-claude` is disabled and the offline install omits the nested Claude ELF
- **THEN** `src_install` succeeds

### Requirement: No completions surface

The ebuild SHALL NOT inherit `shell-completion` and SHALL NOT declare bash, zsh, or fish completion USE flags.

#### Scenario: No completion USE flags

- **WHEN** the ebuild is inspected
- **THEN** it does not declare `bash-completion`, `zsh-completion`, or `fish-completion` USE flags
- **AND** it does not inherit `shell-completion`
- **AND** `IUSE` contains `bundled-claude`, `external-claude`, and `test` and no completion flag

### Requirement: Offline src_test version smoke

The ebuild SHALL include `test` in `IUSE` and set `RESTRICT` to include `!test? ( test )`. `src_test` SHALL install the package into a temporary prefix from the offline deps cache, passing `--omit=optional` when `bundled-claude` is disabled, and SHALL run `claude-agent-acp --version` there. The phase SHALL fail unless that command exits 0 and its stdout is the package PV. The test phase SHALL NOT require network access and SHALL NOT treat `--help` as the smoke command. The version check SHALL pass with `bundled-claude` disabled, and SHALL pass with `external-claude` enabled and `CLAUDE_CODE_EXECUTABLE` unset.

#### Scenario: Offline version smoke

- **WHEN** Portage runs `src_test` with network isolation for a live PV
- **THEN** the phase installs from the deps cache offline
- **AND** `claude-agent-acp --version` exits 0 with stdout equal to that PV

#### Scenario: Default USE omits the optional CLI in src_test

- **WHEN** `src_test` runs with `bundled-claude` disabled
- **THEN** the temporary npm install passes `--omit=optional`
- **AND** `claude-agent-acp --version` still exits 0 with stdout equal to the PV

#### Scenario: External USE omits the optional CLI in src_test

- **WHEN** `src_test` runs with `external-claude` enabled, `bundled-claude` disabled, and `CLAUDE_CODE_EXECUTABLE` unset
- **THEN** the temporary npm install passes `--omit=optional`
- **AND** `claude-agent-acp --version` exits 0 with stdout equal to the PV

### Requirement: Operator smoke acceptance

After overlay and assets are published, the operator SHALL verify the seed by emerging `=dev-util/claude-agent-acp-0.81.1` and running `claude-agent-acp --version`. That command SHALL exit 0 and report `0.81.1`. This is the seed acceptance gate before the manager-driven bump to a newer upstream PV is attempted.

#### Scenario: Smoke command

- **WHEN** seed publish is complete
- **THEN** emerge of `=dev-util/claude-agent-acp-0.81.1` succeeds
- **AND** `claude-agent-acp --version` exits 0 and reports `0.81.1`
