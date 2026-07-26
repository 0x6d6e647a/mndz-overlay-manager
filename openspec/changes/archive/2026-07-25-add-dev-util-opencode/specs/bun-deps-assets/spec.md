## MODIFIED Requirements

### Requirement: engines.bun requirement probe

For each candidate PV used in bun runtime-lane planning or BDEPEND alignment, the program SHALL obtain a Bun minimum version from the package’s root `package.json` at the corresponding GitHub tag (or equivalent fetch) using this order: (1) if `engines.bun` is present and parseable, use that requirement; (2) else if `packageManager` matches the form `bun@X.Y.Z` (optional leading `v` on the version; optional build metadata after `X.Y.Z` SHALL be ignored for the numeric minimum), use `X.Y.Z` as the minimum; (3) else hard-fail planning for that candidate with an error that identifies the parse failure. For `engines.bun`, the program SHALL parse minimum forms: bare version `X.Y.Z`, optional leading `v`, or a `>=X.Y.Z` range. Complex ranges (including `^`, `||`, `<`, and `*`) SHALL be treated as unparseable. When both `engines.bun` and `packageManager` are present and `engines.bun` is parseable, `engines.bun` SHALL win.

#### Scenario: ralph-tui style engines

- **WHEN** `package.json` has `"engines": { "bun": ">=1.3.6" }`
- **THEN** the required bun version used for ceilings and BDEPEND is `1.3.6`

#### Scenario: packageManager fallback for opencode

- **WHEN** `package.json` omits parseable `engines.bun` and has `"packageManager": "bun@1.3.14"`
- **THEN** the required bun version used for ceilings and BDEPEND is `1.3.14`

#### Scenario: engines.bun wins over packageManager

- **WHEN** `package.json` has `"engines": { "bun": ">=1.2.0" }` and `"packageManager": "bun@1.3.14"`
- **THEN** the required bun version is `1.2.0`

#### Scenario: Missing both hard-fails plan

- **WHEN** a required candidate’s `package.json` omits parseable `engines.bun` and omits a parseable `packageManager` `bun@X.Y.Z`
- **THEN** package planning hard-fails

### Requirement: bun-bin BDEPEND greater-or-equal

When applying overlay ebuild changes for a planned bun PV, the program SHALL ensure the ebuild declares `>=dev-lang/bun-bin-<version>` where `<version>` is the probed Bun minimum for that PV (from `engines.bun` or `packageManager` fallback). The program SHALL insert or replace the `dev-lang/bun-bin` atom accordingly and SHALL NOT remove unrelated dependency atoms. The atom SHALL use a greater-or-equal lower bound (not a forced exact pin). The program SHALL NOT require or rewrite `RDEPEND` to include bun-bin solely because the package uses `DepsAndAssets Bun` (compiled packages MAY depend on other runtime packages such as ripgrep without runtime bun).

#### Scenario: Insert bun-bin BDEPEND

- **WHEN** the ebuild lacks a matching bun-bin atom and the probe requires `1.3.6`
- **THEN** after overlay rewrite the ebuild contains `>=dev-lang/bun-bin-1.3.6`

#### Scenario: Replace outdated bun-bin atom

- **WHEN** the ebuild has `>=dev-lang/bun-bin-1.2.0` and the probe requires `1.3.6`
- **THEN** after rewrite the atom is `>=dev-lang/bun-bin-1.3.6`

#### Scenario: RDEPEND without bun-bin is preserved

- **WHEN** the ebuild has `RDEPEND="sys-apps/ripgrep"` and `BDEPEND=">=dev-lang/bun-bin-1.3.14"` and the probe still requires `1.3.14`
- **THEN** after rewrite `RDEPEND` still does not require the manager to inject bun-bin and still contains `sys-apps/ripgrep`

### Requirement: Host Bun gate on full path

After determining the Bun requirement for a PV on the full materialize path, the program SHALL compare the host `bun` version to that requirement. If the host is strictly older, the program SHALL hard-fail that PV before `bun install` and SHALL NOT publish assets or mutate the overlay for that attempt. The reuse path SHALL NOT apply this host gate.

#### Scenario: Host too old

- **WHEN** the probe requires `1.3.6` and the host Bun is older
- **THEN** full-path materialize hard-fails without publishing assets

## ADDED Requirements

### Requirement: Models companion distfile for opencode

For `dev-util/opencode` full-path materialization of PV, after (or as part of) Bun deps tarball construction, the program SHALL fetch `https://models.dev/api.json` and write the response body to a distfile named `{pn}-{pv}-models.json` (overlay PN and PV without revision). Fetch or write failure SHALL hard-fail that PV before assets publish. The models distfile SHALL be published and reused together with the deps tarball as specified by assets-publish multi-asset rules. The program SHALL NOT require Portage emerge to fetch models.dev.

#### Scenario: Models basename for opencode

- **WHEN** models snapshot construction succeeds for PN `opencode` at PV `1.18.4`
- **THEN** the output file is named `opencode-1.18.4-models.json`

#### Scenario: Models fetch failure hard-fails

- **WHEN** `https://models.dev/api.json` cannot be fetched during full materialize for opencode
- **THEN** that PV hard-fails without publishing a release that omits models

### Requirement: Opencode enabled end-to-end

`dev-util/opencode` SHALL use runtime lanes against overlay `dev-lang/bun-bin`, GitHub candidates under the shared candidate rule, Bun requirement probe (including `packageManager` fallback), multi-asset deps+models publish/reuse, and overlay apply as specified for `DepsAndAssets Bun`. The package SHALL NOT soft-skip solely because deps or models assets are required. The hardcoded policy source SHALL be GitHub `anomalyco/opencode` with tag prefix `v`.

#### Scenario: No longer unsupported

- **WHEN** policy is resolved and apply runs for an outdated `dev-util/opencode`
- **THEN** the program does not soft-skip with reason unsupported deps assets

#### Scenario: Policy source and technique

- **WHEN** policy is resolved for `dev-util/opencode`
- **THEN** the source is GitHub `anomalyco/opencode` with prefix `v` and the technique is `DepsAndAssets Bun`
