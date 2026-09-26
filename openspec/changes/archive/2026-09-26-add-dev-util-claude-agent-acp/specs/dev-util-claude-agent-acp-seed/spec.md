# dev-util-claude-agent-acp-seed Specification

## Purpose

Product truth for the manually seeded `dev-util/claude-agent-acp` overlay package (frozen PV 0.81.1): scoped npm packaging, offline deps assets, the glibc amd64 Claude CLI, node floor, `KEYWORDS`, offline `src_test`, and operator smoke acceptance. This is overlay/seed truth, not mndz-overlay-manager runtime behavior.

## ADDED Requirements

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

### Requirement: Installed command name

`src_install` SHALL install the upstream bin as `/usr/bin/claude-agent-acp` via an offline global npm install from the deps cache into `${ED}/usr`. The ebuild SHALL NOT install `/usr/bin/claude`.

#### Scenario: Bin name

- **WHEN** the seed package is emerged
- **THEN** `/usr/bin/claude-agent-acp` exists
- **AND** `/usr/bin/claude` is absent

### Requirement: Prebuilt Claude CLI is not stripped

The ebuild SHALL set `QA_PREBUILT` so Portage does not strip the nested glibc x86-64 Claude CLI installed by the optional dependency `@anthropic-ai/claude-agent-sdk-linux-x64`. The pattern SHALL cover `usr/lib*/node_modules/@agentclientprotocol/claude-agent-acp/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64/claude`.

#### Scenario: QA_PREBUILT pattern

- **WHEN** the ebuild is inspected
- **THEN** `QA_PREBUILT` includes `usr/lib*/node_modules/@agentclientprotocol/claude-agent-acp/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64/claude`

### Requirement: No completions surface

The ebuild SHALL NOT inherit `shell-completion` and SHALL NOT declare bash, zsh, or fish completion USE flags.

#### Scenario: No completion USE flags

- **WHEN** the ebuild is inspected
- **THEN** it does not declare `bash-completion`, `zsh-completion`, or `fish-completion` USE flags
- **AND** it does not inherit `shell-completion`
- **AND** `IUSE` contains `test` and no other flag

### Requirement: Offline src_test version smoke

The ebuild SHALL include `test` in `IUSE` and set `RESTRICT` to include `!test? ( test )`. `src_test` SHALL install the package into a temporary prefix from the offline deps cache and SHALL run `claude-agent-acp --version` there. The phase SHALL fail unless that command exits 0 and its stdout is the package PV. The test phase SHALL NOT require network access and SHALL NOT treat `--help` as the smoke command.

#### Scenario: Offline version smoke

- **WHEN** Portage runs `src_test` with network isolation for PV `0.81.1`
- **THEN** the phase installs from the deps cache offline
- **AND** `claude-agent-acp --version` exits 0 with stdout `0.81.1`

### Requirement: Operator smoke acceptance

After overlay and assets are published, the operator SHALL verify the seed by emerging `=dev-util/claude-agent-acp-0.81.1` and running `claude-agent-acp --version`. That command SHALL exit 0 and report `0.81.1`. This is the seed acceptance gate before the manager-driven bump to a newer upstream PV is attempted.

#### Scenario: Smoke command

- **WHEN** seed publish is complete
- **THEN** emerge of `=dev-util/claude-agent-acp-0.81.1` succeeds
- **AND** `claude-agent-acp --version` exits 0 and reports `0.81.1`
