## ADDED Requirements

### Requirement: Bun cache tarball from GitHub tag

For `DepsAndAssets Bun` full-path materialization of PV, the program SHALL: (1) clone the package’s GitHub source into a temporary directory and check out the tag formed by the source tag prefix plus that PV; (2) require a `bun.lock` at the repository root and hard-fail if missing; (3) run `bun install --frozen-lockfile --cache-dir <bun-cache-path>` with the cache directory outside or beside the clone as needed so the cache can be packaged; (4) create `{pn}-{pv}-deps.tar.xz` whose top-level entry is `bun-cache/`, using xz compression suitable for large artifacts (including multi-threaded xz settings equivalent to `XZ_OPT=-T0 -9`). The program SHALL implement this in Haskell orchestration and SHALL NOT invoke overlay Python helper scripts. The temporary clone SHALL be removed when the PV attempt finishes.

#### Scenario: Tarball layout for ralph-tui

- **WHEN** bun cache construction succeeds for PN `ralph-tui` at PV `0.12.0`
- **THEN** the output file is named `ralph-tui-0.12.0-deps.tar.xz` and unpacking yields a top-level `bun-cache` directory

#### Scenario: Missing lockfile hard-fails

- **WHEN** the checked-out tag has no `bun.lock` at the repository root
- **THEN** materialization hard-fails before assets publish

### Requirement: Bun source and technique pairing

Apply for `DepsAndAssets Bun` SHALL require `UpdateSource` to be `GitHub`. If the technique is `DepsAndAssets Bun` but the source is not `GitHub`, apply SHALL hard-fail without publishing assets.

#### Scenario: Wrong source type

- **WHEN** technique is `DepsAndAssets Bun` and source is `Npm`
- **THEN** apply hard-fails before materialization

### Requirement: engines.bun requirement probe

For each candidate PV used in bun runtime-lane planning or BDEPEND alignment, the program SHALL obtain `engines.bun` from the package’s `package.json` at the corresponding GitHub tag (or equivalent fetch). The program SHALL parse minimum forms: bare `X.Y.Z`, optional leading `v`, or `>=X.Y.Z`. Complex ranges SHALL be treated as unparseable. Missing or unparseable `engines.bun` for a candidate that planning must evaluate SHALL hard-fail package planning with an error that identifies the parse failure.

#### Scenario: ralph-tui style engines

- **WHEN** `package.json` has `"engines": { "bun": ">=1.3.6" }`
- **THEN** the required bun version used for ceilings and BDEPEND is `1.3.6`

#### Scenario: Missing engines hard-fails plan

- **WHEN** a required candidate’s `package.json` omits parseable `engines.bun`
- **THEN** package planning hard-fails

### Requirement: bun-bin BDEPEND greater-or-equal

When applying overlay ebuild changes for a planned bun PV, the program SHALL ensure the ebuild declares `>=dev-lang/bun-bin-<version>` where `<version>` is the probed `engines.bun` minimum for that PV. The program SHALL insert or replace the `dev-lang/bun-bin` atom accordingly and SHALL NOT remove unrelated dependency atoms. The atom SHALL use a greater-or-equal lower bound (not a forced exact pin).

#### Scenario: Insert bun-bin BDEPEND

- **WHEN** the ebuild lacks a matching bun-bin atom and engines require `1.3.6`
- **THEN** after overlay rewrite the ebuild contains `>=dev-lang/bun-bin-1.3.6`

#### Scenario: Replace outdated bun-bin atom

- **WHEN** the ebuild has `>=dev-lang/bun-bin-1.2.0` and engines require `1.3.6`
- **THEN** after rewrite the atom is `>=dev-lang/bun-bin-1.3.6`

### Requirement: Host Bun gate on full path

After determining the bun requirement for a PV on the full materialize path, the program SHALL compare the host `bun` version to that requirement. If the host is strictly older, the program SHALL hard-fail that PV before `bun install` and SHALL NOT publish assets or mutate the overlay for that attempt. The reuse path SHALL NOT apply this host gate.

#### Scenario: Host too old

- **WHEN** engines require `1.3.6` and the host Bun is older
- **THEN** full-path materialize hard-fails without publishing assets

### Requirement: Overlay bun-bin ceilings

Bun runtime-lane ceilings SHALL be read from `{overlay-path}/dev-lang/bun-bin` non-live ebuilds. Because overlay packages conventionally use tilde KEYWORDS only, plain ceilings MAY be absent so that only tilde lanes produce targets; KEYWORDS assembly SHALL still follow runtime-lanes rules.

#### Scenario: Tilde-only bun-bin

- **WHEN** bun-bin ebuilds declare only `~amd64` and `~arm64`
- **THEN** planned package KEYWORDS for a single collapsed PV may be `~amd64 ~arm64` without bare arches

### Requirement: ralph-tui enabled end-to-end

`dev-util/ralph-tui` SHALL use runtime lanes against overlay `dev-lang/bun-bin`, GitHub candidates under the shared candidate rule, deps asset publish/reuse, and overlay apply as specified for `DepsAndAssets Bun`. The package SHALL NOT soft-skip solely because deps assets are required.

#### Scenario: No longer unsupported

- **WHEN** policy is resolved and apply runs for an outdated `dev-util/ralph-tui`
- **THEN** the program does not soft-skip with reason unsupported deps assets
