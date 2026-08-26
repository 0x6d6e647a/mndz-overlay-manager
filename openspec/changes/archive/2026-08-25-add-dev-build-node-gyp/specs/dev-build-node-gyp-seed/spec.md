## Purpose

Requirements for the overlay package `dev-build/node-gyp`: npm identity, offline deps distfile, install layout and wrapper, KEYWORDS, isolation from opencode DEPEND, and operator smoke. Overlay/seed product truth, not manager runtime.

## ADDED Requirements

### Requirement: Package identity and version pin

The seeded package SHALL be `dev-build/node-gyp` at Portage version `13.0.0`, corresponding to npm `node-gyp@13.0.0`. The seed SHALL NOT use a newer npm version for the initial ebuild. The live ebuild filename SHALL be `node-gyp-13.0.0.ebuild` without a `-r0` suffix; content-only fixes SHALL use `-r1` or greater when a revision bump is required.

#### Scenario: Filename and npm version

- **WHEN** the seed package is added to the overlay
- **THEN** the ebuild path is `dev-build/node-gyp/node-gyp-13.0.0.ebuild` (or `node-gyp-13.0.0-rN.ebuild` only if a content revision is required)
- **AND** the primary source archive is the npm registry tarball for `node-gyp@13.0.0`

### Requirement: Metadata description homepage and remote-id

The ebuild SHALL set `DESCRIPTION` to a short summary synthesizing upstream README (Node.js native addon build tool), `HOMEPAGE` to `https://github.com/nodejs/node-gyp`, and `metadata.xml` SHALL declare GitHub remote-id `nodejs/node-gyp`.

#### Scenario: Homepage and description

- **WHEN** the ebuild and `metadata.xml` are inspected
- **THEN** the homepage is the GitHub URL above
- **AND** `metadata.xml` contains GitHub remote-id `nodejs/node-gyp`

### Requirement: Openspec-shaped SRC_URI with overlay-assets deps

`SRC_URI` SHALL include:

1. the npm registry tarball `https://registry.npmjs.org/node-gyp/-/node-gyp-${PV}.tgz` renamed to `${P}.tgz`
2. the overlay-assets deps archive `node-gyp-${PV}-deps.tar.xz` whose top-level member is `npm-cache/` as specified for `DepsAndAssets Npm`

The ebuild SHALL NOT use a GitHub `archive/refs/tags` URL as the primary source. Compile and install SHALL run `npm --offline` against that cache and SHALL NOT fetch the npm registry.

#### Scenario: SRC_URI has registry tarball and deps

- **WHEN** the ebuild is inspected
- **THEN** `SRC_URI` names the npmjs.org `node-gyp-${PV}.tgz` and an `mndz-overlay-assets` `node-gyp-${PV}-deps.tar.xz`
- **AND** it does not use `archive/refs/tags` as the primary archive

#### Scenario: Emerge is offline for npm

- **WHEN** compile or install runs with Portage network isolation
- **THEN** `npm` is invoked `--offline` against the unpacked deps cache
- **AND** install does not require registry.npmjs.org

### Requirement: Global prefix install and PATH wrapper

Install SHALL use `npm --offline --global --prefix` under `${ED}/usr` (openspec-style) so `node-gyp` is on `PATH`. `/usr/bin/node-gyp` SHALL be a wrapper (or the installed bin plus a wrapper that `exec`s it) that, unless already set, exports `npm_config_nodedir=/usr`, `npm_config_python=/usr/bin/python3`, and `PYTHON=/usr/bin/python3`. The wrapper SHALL NOT set `npm_config_offline`. The package SHALL keep node-gyp’s vendored gyp-next tree from the npm tarball. The ebuild SHALL NOT `RDEPEND` `dev-build/gyp`.

#### Scenario: PATH entry after emerge

- **WHEN** the package is emerged
- **THEN** `/usr/bin/node-gyp` exists and is executable
- **AND** `node-gyp --version` from `PATH` prints a line containing `13.0.0`

#### Scenario: Wrapper defaults nodedir and python

- **WHEN** `node-gyp` is invoked with those variables unset
- **THEN** the process environment includes `npm_config_nodedir=/usr` and `npm_config_python=/usr/bin/python3`

### Requirement: Dependencies and opencode isolation

The ebuild SHALL depend on `>=net-libs/nodejs-22.22.2[npm]` (or the engines minimum for 13.0.0) and on `dev-lang/python`. The seed SHALL NOT add `dev-build/node-gyp` to `dev-util/opencode` `DEPEND`, `RDEPEND`, or `BDEPEND`.

#### Scenario: nodejs npm USE

- **WHEN** the ebuild dependency atoms are inspected
- **THEN** a `net-libs/nodejs` atom with `[npm]` is declared
- **AND** python is declared

#### Scenario: opencode ebuild unchanged for node-gyp

- **WHEN** the seed is complete
- **THEN** `dev-util/opencode` does not list `dev-build/node-gyp` as a dependency

### Requirement: KEYWORDS tilde-only JS arches

The ebuild SHALL set KEYWORDS covering at least `~amd64 ~arm ~arm64 ~loong ~ppc64 ~riscv ~x86` (order may vary; additional openspec-style tokens such as `~x64-macos` are allowed). Every arch token SHALL be tilde-only. The seed SHALL NOT copy bun-bin’s `-*` token. The seed SHALL NOT limit KEYWORDS to opencode’s `~amd64 ~arm64` solely because opencode BDEPENDs bun-bin.

#### Scenario: Keyword set is wider than bun-bin

- **WHEN** the ebuild is inspected
- **THEN** KEYWORDS include `~amd64` and `~arm64` and at least one of `~ppc64` or `~riscv` or `~arm`
- **AND** KEYWORDS do not include bare `amd64` or `-*`

### Requirement: test USE gate

The ebuild SHALL include `test` in `IUSE` and set `RESTRICT` to include `!test? ( test )`. `src_test` SHALL run a minimal offline verification (`node-gyp --version`) when Portage allows the test phase.

#### Scenario: tests restricted when USE=-test

- **WHEN** `USE=-test` and the package is emerged with `FEATURES=test`
- **THEN** the test phase is restricted and does not run package tests

### Requirement: Operator smoke acceptance

After the overlay package is committed with Manifest and package cache, the operator SHALL verify install by emerging `=dev-build/node-gyp-13.0.0` (or the revised `-rN` atom if used) and running `node-gyp --version` from `PATH`. The command SHALL print a line containing `13.0.0`.

#### Scenario: smoke commands

- **WHEN** seed publish is complete
- **THEN** emerge of that atom succeeds
- **AND** `node-gyp --version` from `PATH` prints a line containing 13.0.0
