## Purpose

Product truth for the manually seeded `dev-util/rulesync` overlay package (frozen PV 16.22.1): npm-registry packaging shape, manually materialized offline deps assets release with checksum sidecars, node floor BDEPEND, KEYWORDS, no-completions shape, offline `src_test`, and operator smoke acceptance. This is overlay/seed truth, not mndz-overlay-manager runtime behavior.

## ADDED Requirements

### Requirement: Package identity and version pin

The seeded package SHALL be `dev-util/rulesync` at Portage version `16.22.1`, corresponding to upstream npm package `rulesync` version `16.22.1` (upstream GitHub `dyoshikawa/rulesync` release `v16.22.1`). The seed SHALL NOT use a newer upstream version (including 16.23.0) for the initial ebuild. The live ebuild filename SHALL be `rulesync-16.22.1.ebuild` without a `-r0` suffix; content-only fixes before or after first publish SHALL use `-r1` or greater when a revision bump is required.

#### Scenario: Filename and source

- **WHEN** the seed package is added to the overlay
- **THEN** the ebuild path is `dev-util/rulesync/rulesync-16.22.1.ebuild` (or `rulesync-16.22.1-rN.ebuild` only if a content revision is required)
- **AND** the primary source archive is the npm registry tarball for `rulesync@16.22.1`

### Requirement: Metadata description and license

The ebuild SHALL set `DESCRIPTION` to a short upstream-derived summary (AI-agent configuration generator CLI), `HOMEPAGE` to `https://github.com/dyoshikawa/rulesync`, and `LICENSE` to `MIT`. `metadata.xml` SHALL declare GitHub remote-id `dyoshikawa/rulesync`.

#### Scenario: License and homepage

- **WHEN** the ebuild and metadata are inspected
- **THEN** the homepage is `https://github.com/dyoshikawa/rulesync`
- **AND** `LICENSE` is `MIT`
- **AND** `metadata.xml` declares remote-id type `github` with value `dyoshikawa/rulesync`

### Requirement: npm registry tarball as packaging source

The ebuild's primary `SRC_URI` SHALL fetch the npm registry tarball, parameterized by `${PV}`. The upstream GitHub release single-binary assets (`install.sh`, prebuilt `rulesync-*` platform binaries) SHALL NOT be referenced or installed.

#### Scenario: Primary SRC_URI form

- **WHEN** the ebuild is written
- **THEN** it contains a `SRC_URI` entry of the form `https://registry.npmjs.org/rulesync/-/rulesync-${PV}.tgz -> ${P}.tgz`
- **AND** no `SRC_URI` entry references `install.sh` or a prebuilt `rulesync-<os>-<arch>` binary

### Requirement: Offline deps assets publish

A deps tarball named `rulesync-16.22.1-deps.tar.xz` SHALL be published to `mndz-overlay-assets` as release tag `rulesync-16.22.1`, with `b3`, `sha256`, and `sha512` checksum sidecars committed under `dev-util/rulesync/` in the assets repository and a GPG-signed assets commit. The tarball SHALL contain a top-level `npm-cache/` directory, SHALL omit `npm-cache/_logs/` and `npm-cache/_update-notifier*` members, and SHALL be an xz-compressed stream packed with the hermetic tar/xz rules. The seed materialization SHALL mirror the registry-only npm cache tarball steps of `npm-deps-assets` (npm pack of `rulesync@16.22.1`, npm cache population with an empty userconfig) and SHALL run in the materialize image container, not on the host toolchain. The ebuild SHALL reference the release via a fully parameterized assets `SRC_URI` using `${PV}`.

#### Scenario: Assets URL form

- **WHEN** the ebuild is written
- **THEN** it contains a `SRC_URI` entry of the form `https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/rulesync-${PV}/rulesync-${PV}-deps.tar.xz`

#### Scenario: Tarball layout

- **WHEN** the seeded deps tarball is unpacked
- **THEN** it yields a top-level `npm-cache` directory
- **AND** it contains no `npm-cache/_logs/` members

#### Scenario: Sidecars and signing

- **WHEN** the assets release is published
- **THEN** `dev-util/rulesync/rulesync-16.22.1-deps.tar.xz.{b3,sha256,sha512}` exist in the assets worktree
- **AND** the assets commit adding them is GPG-signed

### Requirement: Node floor BDEPEND atom

The ebuild SHALL declare the build/runtime dependency atom `>=net-libs/nodejs-22.0.0[npm]`, matching the pinned npm version's `engines.node` requirement `>=22.0.0`, with the `[npm]` USE dependency required.

#### Scenario: Nodejs atom

- **WHEN** the ebuild is inspected
- **THEN** it contains the atom `>=net-libs/nodejs-22.0.0[npm]`
- **AND** no nodejs atom in the ebuild requires less than `22.0.0`

### Requirement: KEYWORDS aligned with the npm lane set

The seed ebuild SHALL set tilde-only `KEYWORDS` matching the npm runtime-lane arch set in use by the overlay's npm packages (the `dev-util/openspec` KEYWORDS set at seed time: `~amd64 ~arm ~arm64 ~loong ~ppc64 ~riscv ~x64-macos ~x86`). Later manager rewrites MAY drop arches whose nodejs ceiling is below the engines floor; the seed SHALL NOT keyword arches outside the npm lane set.

#### Scenario: Keyword set

- **WHEN** the ebuild is inspected
- **THEN** `KEYWORDS` is a tilde-only subset of `~amd64 ~arm ~arm64 ~loong ~ppc64 ~riscv ~x64-macos ~x86`
- **AND** it includes `~amd64`

### Requirement: No completions surface

The ebuild SHALL NOT inherit `shell-completion` and SHALL NOT declare bash/zsh/fish completion USE flags; upstream publishes no shell completion generator at the pinned version.

#### Scenario: no completion USE flags

- **WHEN** the ebuild is inspected
- **THEN** it does not declare `bash-completion`, `zsh-completion`, or `fish-completion` USE flags
- **AND** it does not inherit `shell-completion`

### Requirement: Offline src_test smoke

The ebuild SHALL include `test` in `IUSE` and set `RESTRICT` to include `!test? ( test )`. `src_test` SHALL install the package into a temporary prefix from the offline deps cache and SHALL run `rulesync --help` there, failing if it exits non-zero. The test phase SHALL NOT require network access.

#### Scenario: offline help smoke

- **WHEN** Portage runs `src_test` with network isolation
- **THEN** the phase installs from the deps cache offline and `rulesync --help` exits successfully

### Requirement: Operator smoke acceptance

After overlay and assets are published, the operator SHALL verify the seed by emerging `=dev-util/rulesync-16.22.1` and running `rulesync --version` and `rulesync --help`. `--version` SHALL exit successfully reporting `16.22.1`; `--help` SHALL exit successfully. This is the seed acceptance gate before the manager-driven bump to a newer upstream PV is attempted.

#### Scenario: smoke commands

- **WHEN** seed publish is complete
- **THEN** emerge of `=dev-util/rulesync-16.22.1` succeeds
- **AND** `rulesync --version` exits successfully and reports `16.22.1`
- **AND** `rulesync --help` exits successfully