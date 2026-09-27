# Spec Delta

## MODIFIED Requirements

### Requirement: engines.node requirement probe

For each candidate PV used in npm runtime-lane planning or BDEPEND alignment, the program SHALL obtain the package’s `engines.node` requirement from npm registry metadata and/or the packed package’s `package.json`. When that field is present, the program SHALL parse a **minimum** Node version from:

1. a bare version `X.Y.Z`, optional leading `v`, or a `>=X.Y.Z` range
2. a caret range `^X.Y.Z` (minimum `X.Y.Z`; caret upper bound is not encoded in the Portage atom)
3. a disjunction of such clauses joined by `||` (the **lowest** lower-bound among clauses)

When registry metadata and the packed `package.json` both omit `engines` or omit `engines.node`, the program SHALL use the minimum version from the donor ebuild’s existing `>=net-libs/nodejs-<version>[npm]` atom as that PV’s node requirement. The donor SHALL be the highest local non-live ebuild the apply rewrite copies. A candidate with this donor-derived requirement SHALL remain eligible for lane selection when the requirement is less than or equal to the lane ceiling. The program SHALL hard-fail planning for that candidate when the donor ebuild has no `net-libs/nodejs` atom.

Unparseable forms (`*`, `<`, hyphen ranges, empty, or other combinators the parser does not support) SHALL still hard-fail planning for a candidate that planning must evaluate, with an error that identifies the parse failure. A present but unparseable `engines.node` SHALL NOT fall back to the donor atom.

#### Scenario: openspec style engines

- **WHEN** registry metadata has `"engines": { "node": ">=20.19.0" }`
- **THEN** the required node version used for ceilings and BDEPEND is `20.19.0`

#### Scenario: caret range is a minimum

- **WHEN** a candidate’s `engines.node` is `^22.22.2`
- **THEN** the required node version used for ceilings and BDEPEND is `22.22.2`

#### Scenario: node-gyp style disjunction

- **WHEN** a candidate’s `engines.node` is `^22.22.2 || ^24.15.0 || >=26.0.0`
- **THEN** the required node version used for ceilings and BDEPEND is `22.22.2`

#### Scenario: Complex engines hard-fails plan

- **WHEN** a candidate’s `engines.node` is a complex range the parser does not support (`*`, `<`, hyphen ranges)
- **THEN** package planning hard-fails rather than silently skipping or inventing a requirement

#### Scenario: star still hard-fails plan

- **WHEN** a candidate’s `engines.node` is `*`
- **THEN** package planning hard-fails rather than silently skipping or inventing a requirement

#### Scenario: absent engines uses the donor atom

- **WHEN** registry metadata for a candidate omits `engines.node` and the donor ebuild contains `>=net-libs/nodejs-22[npm]`
- **THEN** the required node version used for ceilings and BDEPEND is `22`
- **AND** the candidate remains eligible on nodejs lanes whose ceiling is at least `22`

#### Scenario: absent engines without a donor atom hard-fails

- **WHEN** registry metadata for a candidate omits `engines.node` and the donor ebuild has no `net-libs/nodejs` atom
- **THEN** package planning hard-fails for that candidate
- **AND** the error identifies the missing donor atom

#### Scenario: present engines replaces the donor atom

- **WHEN** registry metadata has `"engines": { "node": ">=20.19.0" }` and the donor ebuild contains `>=net-libs/nodejs-22[npm]`
- **THEN** the required node version used for ceilings and BDEPEND is `20.19.0`

### Requirement: Nodejs BDEPEND with npm USE

When applying overlay ebuild changes for a planned npm PV, the program SHALL ensure the ebuild declares a build/runtime dependency atom `>=net-libs/nodejs-<version>[npm]` where `<version>` is the node requirement resolved for that PV (the probed `engines.node` minimum, or the donor atom’s version when `engines.node` is absent). The program SHALL insert or replace the `net-libs/nodejs` atom so it matches that requirement and SHALL NOT remove unrelated dependency atoms. The `[npm]` USE dependency is required.

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

#### Scenario: Absent engines keeps the donor atom

- **WHEN** the candidate omits `engines.node` and the donor ebuild contains `>=net-libs/nodejs-22[npm]`
- **THEN** after overlay rewrite the ebuild contains `>=net-libs/nodejs-22[npm]` with a single `[npm]` USE dependency

## ADDED Requirements

### Requirement: codex-acp enabled end-to-end

`dev-util/codex-acp` SHALL use runtime lanes against gentoo `net-libs/nodejs`, npm registry candidates for `@agentclientprotocol/codex-acp` under the shared candidate rule, deps asset publish/reuse, and overlay apply as specified for `DepsAndAssets Npm`. The package SHALL NOT soft-skip solely because npm deps assets are required. The hardcoded policy source SHALL be npm package `@agentclientprotocol/codex-acp`.

#### Scenario: No longer unsupported

- **WHEN** policy is resolved and apply runs for an outdated `dev-util/codex-acp`
- **THEN** the program does not soft-skip with reason unsupported deps assets

#### Scenario: Scoped registry package

- **WHEN** full-path materialize packs a PV for this package
- **THEN** `npm pack` uses `@agentclientprotocol/codex-acp` at that PV
- **AND** the deps distfile basename uses PN `codex-acp`
