## Purpose

Npm registry-only deps cache tarball build, `engines.node` probing, nodejs BDEPEND with `[npm]` USE, host Node gate, and `dev-util/openspec` enablement under `DepsAndAssets Npm`.

## Requirements

### Requirement: Registry-only npm cache tarball

For `DepsAndAssets Npm` full-path materialization of PV, the program SHALL, in a temporary directory without requiring a git clone of the package source: (1) run `npm pack` for the configured npm package at that version (specifier `{npmPackage}@{pv}`); (2) populate an `npm-cache/` directory via `npm --cache <npm-cache-path> install` of the produced tarball; (3) create `{pn}-{pv}-deps.tar.xz` whose top-level entry is `npm-cache/`, using xz compression suitable for large artifacts (including multi-threaded xz settings equivalent to `XZ_OPT=-T0 -9` when invoking tar). The program SHALL implement this in-process/Haskell orchestration and SHALL NOT invoke overlay Python helper scripts.

#### Scenario: Tarball layout for openspec

- **WHEN** npm cache construction succeeds for PN `openspec` at PV `1.4.2`
- **THEN** the output file is named `openspec-1.4.2-deps.tar.xz` and unpacking yields a top-level `npm-cache` directory

#### Scenario: Scoped registry package

- **WHEN** the npm source package is `@fission-ai/openspec` and PV is `1.4.2`
- **THEN** `npm pack` uses `@fission-ai/openspec@1.4.2` while the deps distfile basename uses PN `openspec`

### Requirement: Npm source and technique pairing

Apply for `DepsAndAssets Npm` SHALL require `UpdateSource` to be `Npm`. If the technique is `DepsAndAssets Npm` but the source is not `Npm`, apply SHALL hard-fail without publishing assets.

#### Scenario: Wrong source type

- **WHEN** technique is `DepsAndAssets Npm` and source is `GitHub`
- **THEN** apply hard-fails before materialization

### Requirement: engines.node requirement probe

For each candidate PV used in npm runtime-lane planning or BDEPEND alignment, the program SHALL obtain the package’s `engines.node` requirement from npm registry metadata and/or the packed package’s `package.json`. The program SHALL parse minimum forms: a bare version `X.Y.Z`, optional leading `v`, or a `>=X.Y.Z` range. Complex ranges (including `^`, `||`, `<`, and `*`) SHALL be treated as unparseable. If the requirement is missing or unparseable for a candidate that planning must evaluate, planning for that package SHALL hard-fail with an error that identifies the parse failure (so engine parsing gaps are visible).

#### Scenario: openspec style engines

- **WHEN** registry metadata has `"engines": { "node": ">=20.19.0" }`
- **THEN** the required node version used for ceilings and BDEPEND is `20.19.0`

#### Scenario: Complex engines hard-fails plan

- **WHEN** a candidate’s `engines.node` is a complex range the parser does not support
- **THEN** package planning hard-fails rather than silently skipping or inventing a requirement

### Requirement: Nodejs BDEPEND with npm USE

When applying overlay ebuild changes for a planned npm PV, the program SHALL ensure the ebuild declares a build/runtime dependency atom `>=net-libs/nodejs-<version>[npm]` where `<version>` is the probed `engines.node` minimum for that PV. The program SHALL insert or replace the `net-libs/nodejs` atom so it matches that requirement and SHALL NOT remove unrelated dependency atoms. The `[npm]` USE dependency is required.

Replacement SHALL consume the full prior Portage atom tail for that package (version, optional slot, and full USE dependency bracket including flag names), so the result is a single valid atom. The program SHALL NOT leave residual USE text (for example a dangling `npm]`) that would produce invalid tokens such as `[npm]npm]`. When the atom appears on `RDEPEND` (or another dependency assignment) rather than only on `BDEPEND`, rewrite of that occurrence SHALL still produce a valid atom (openspec-style ebuilds may set `BDEPEND="${RDEPEND}"`).

#### Scenario: Insert nodejs BDEPEND

- **WHEN** the ebuild lacks a matching nodejs atom and engines require `20.19.0`
- **THEN** after overlay rewrite the ebuild contains `>=net-libs/nodejs-20.19.0[npm]`

#### Scenario: Replace outdated nodejs atom

- **WHEN** the ebuild has `>=net-libs/nodejs-18[npm]` (or another older atom) and engines require `20.19.0`
- **THEN** after rewrite the nodejs atom is exactly `>=net-libs/nodejs-20.19.0[npm]` with a single `[npm]` USE and no residual flag text after the closing `]`

#### Scenario: Same-version atom with USE is not mangled

- **WHEN** the ebuild already has `RDEPEND=">=net-libs/nodejs-20.19.0[npm]"` (or the same atom on `BDEPEND`) and engines still require `20.19.0`
- **THEN** after any rewrite that touches that atom the ebuild still contains a valid Portage atom `>=net-libs/nodejs-20.19.0[npm]` and does not contain the substring `[npm]npm]`

#### Scenario: RDEPEND shared with BDEPEND

- **WHEN** the ebuild has `RDEPEND=">=net-libs/nodejs-20.19.0[npm]"` and `BDEPEND="${RDEPEND}"`
- **THEN** rewrite of the `net-libs/nodejs` occurrence on the `RDEPEND` line leaves a valid atom so Portage metadata for both `RDEPEND` and `BDEPEND` accepts the ebuild

### Requirement: Host Node gate on full path

After determining the node requirement for a PV on the full materialize path, the program SHALL compare the host `node` (or equivalent) version to that requirement. If the host is strictly older, the program SHALL hard-fail that PV before `npm pack`/cache population and SHALL NOT publish assets or mutate the overlay for that attempt. The reuse path SHALL NOT apply this host gate.

#### Scenario: Host too old

- **WHEN** engines require `20.19.0` and the host Node is older
- **THEN** full-path materialize hard-fails without publishing assets

### Requirement: openspec enabled end-to-end

`dev-util/openspec` SHALL use runtime lanes against gentoo `net-libs/nodejs`, npm registry candidates under the shared candidate rule, deps asset publish/reuse, and overlay apply as specified for `DepsAndAssets Npm`. The package SHALL NOT soft-skip solely because npm deps assets are required.

#### Scenario: No longer unsupported

- **WHEN** policy is resolved and apply runs for an outdated `dev-util/openspec`
- **THEN** the program does not soft-skip with reason unsupported deps assets
