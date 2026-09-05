## Purpose

Define overlay-internal apply wait-edges from update technique so `update` withholds runtime-lane consumers until an overlay ceiling provider’s signed commit, using a hypothetical-at-remote working plan when that provider is selected and needs work; and so an unselected stale provider is a hard-fail of the consumer on plan-delta (fail-closed when that provider’s latest cannot be fetched).

## Requirements

### Requirement: Overlay wait-edges follow technique ceiling source

For `DepsAndAssets` packages whose runtime-lane ceiling source is a package in the configured overlay, that overlay package SHALL be the overlay wait-edge **provider** and the `DepsAndAssets` package SHALL be the **consumer**. Today that mapping is: ecosystem `Bun` waits on `dev-lang/bun-bin`. Ecosystems whose ceilings come from the gentoo repository (Go, Npm, Cargo, Sbcl) SHALL NOT create overlay wait-edges. The program SHALL NOT parse ebuild `DEPEND`, `RDEPEND`, or `BDEPEND` to discover these **ceiling wait-edges**, and SHALL NOT require a second per-package edge map for them. Parsing `DEPEND*` for overlay-internal atom closure is specified by `overlay-atom-closure` and SHALL NOT create overlay wait-edges. Adding a package whose technique is `DepsAndAssets Bun` SHALL create the bun-bin wait-edge without a separate edge-table edit.

#### Scenario: ralph waits on bun-bin

- **WHEN** policy for `dev-util/ralph-tui` is `DepsAndAssets Bun` and `dev-lang/bun-bin` is in the `update` selection
- **THEN** ralph-tui has an overlay wait-edge on bun-bin

#### Scenario: mise has no overlay wait-edge

- **WHEN** policy for `dev-util/mise` is `DepsAndAssets Cargo`
- **THEN** mise has no overlay wait-edge

#### Scenario: New Bun package inherits the edge

- **WHEN** a newly configured overlay package uses `DepsAndAssets Bun`
- **THEN** that package waits on `dev-lang/bun-bin` without a separate edge-table entry

#### Scenario: Atom-closure parse does not create a Cargo wait-edge

- **WHEN** `dev-util/hk` ebuild `RDEPEND` contains `dev-util/usage`
- **THEN** hk has no overlay wait-edge on usage solely because of that atom

### Requirement: Selected provider needs-work uses hypothetical ceilings as the working plan

When an overlay wait-edge provider is **in this `update` selection** and its plan is needs-work (GitMv local PV strictly less than remote latest), every selected consumer of that provider SHALL be planned against **hypothetical** overlay ceilings: ceiling discovery as if the newest non-live provider ebuild’s version were that provider’s remote latest and that ebuild’s KEYWORDS were unchanged (the same construction specified for unselected plan-delta). That hypothetical plan SHALL be the consumer’s **working plan** for classify, needs-work, materialize-image floors, and apply. The program SHALL NOT use the start-of-run on-disk provider ceiling plan as the working plan for those consumers, and SHALL NOT rediscover ceilings from overlay disk and re-plan those consumers after the provider’s signed overlay commit.

Unselected-provider plan-delta refuse and fail-closed SHALL remain as already specified. `outdated` SHALL NOT be required to print hypothetical ceilings.

#### Scenario: Untargeted update plans ralph against bun-bin remote

- **WHEN** untargeted `update` selects bun-bin and ralph-tui, on-disk bun-bin is `1.3.14`, bun-bin remote latest is `1.4.0`, and ralph-tui’s unique PV set under bun-bin `1.4.0` ceilings differs from the on-disk `1.3.14` ceilings
- **THEN** ralph-tui’s working plan is the `1.4.0` hypothetical plan
- **AND** the program does not apply the `1.3.14` on-disk-ceiling plan for ralph-tui

#### Scenario: Provider already current uses on-disk ceilings

- **WHEN** bun-bin is selected and the initial plan soft-skips it as already at latest
- **THEN** selected Bun consumers are planned against on-disk bun-bin ceilings
- **AND** hypothetical-at-remote is not the working plan solely because bun-bin is in the selection

### Requirement: Hypo-planned consumer overlay write asserts provider PV

Before overlay mutation (ebuild rewrite, Manifest, egencache, signed commit) of a consumer whose working plan used hypothetical provider ceilings, the program SHALL verify that the overlay provider’s newest non-live ebuild version equals the remote PV that working plan assumed. On mismatch the consumer SHALL hard-fail without overlay mutation. The error SHALL name the consumer, the provider, the planned provider PV, and the overlay provider PV, and SHALL state that the provider bump did not land as planned and that the consumer was not mutated. Recovery SHALL mention restoring or finishing the provider package.

#### Scenario: Ralph hard-fails when bun-bin PV does not match the plan

- **WHEN** ralph-tui’s working plan assumed bun-bin `1.4.0` and overlay bun-bin’s newest non-live ebuild is `1.3.14` at ralph-tui overlay-write time
- **THEN** ralph-tui hard-fails naming `dev-lang/bun-bin`, `1.4.0`, and `1.3.14`
- **AND** ralph-tui overlay files are not rewritten or committed

#### Scenario: Matching PV allows ralph overlay write

- **WHEN** ralph-tui’s working plan assumed bun-bin `1.4.0` and overlay bun-bin’s newest non-live ebuild is `1.4.0`
- **THEN** the assert does not fail solely for that PV match

### Requirement: Admit-when-ready apply under overlay wait-edges

During `update` mutate, a selected package SHALL be **admitted** to phase-1 apply only when every overlay wait-edge predecessor that is also in this run’s selection has reached a terminal plan-or-apply outcome that is not a hard-fail (signed overlay commit success, or a no-work / soft-skip plan result). Packages with no unmet overlay predecessor in this selection MAY start together under the `--jobs` limit, including GitMv overlay providers overlapping independent packages. A consumer SHALL NOT occupy a package job slot while waiting. Overlay signed commits SHALL remain sequential as specified by `update-apply`.

When an overlay wait-edge provider is in the selection and its initial plan is needs-work, every selected consumer of that provider SHALL be **withheld** from mutate until that provider’s signed overlay commit (or a no-work / soft-skip plan result). Those consumers SHALL use the hypothetical working plan specified above, not a later disk re-plan. The program SHALL NOT apply a consumer’s on-disk-ceiling plan in the same run as a selected provider needs-work.

#### Scenario: Independents overlap bun-bin

- **WHEN** the user runs untargeted `update` and bun-bin, mise, and ralph-tui all need work
- **THEN** bun-bin and mise may run phase-1 concurrently under `--jobs`
- **AND** ralph-tui does not start phase-1 until bun-bin has a signed overlay commit

#### Scenario: Consumer not applied under old ceiling in the same run

- **WHEN** bun-bin needs work in the run and ralph-tui’s on-disk-ceiling plan would materialize a PV under the old bun-bin ceiling
- **THEN** that on-disk-ceiling ralph-tui plan is not applied
- **AND** ralph-tui is applied, if at all, using the hypothetical working plan after bun-bin’s signed commit

#### Scenario: Provider already current does not withhold

- **WHEN** bun-bin is selected and the initial plan soft-skips it as already at latest
- **THEN** selected Bun consumers may be admitted with other packages without waiting on a bun-bin commit

### Requirement: Re-plan consumers after provider signed commit

After an overlay wait-edge provider in this run creates a successful signed overlay commit, the program SHALL admit each withheld consumer using that consumer’s **already computed hypothetical working plan**. The program SHALL NOT rediscover that provider’s overlay runtime ceilings from overlay disk for those consumers and SHALL NOT re-list or re-probe upstream solely to replace the hypothetical plan. The program SHALL classify reuse versus full, evaluate conditional `update` preflight, and run the disk-space gate for those consumers’ needs-work units before admitting them to language materialize, as specified by `update-command` and `disk-space-preflight`. Materialize-image ensure for those consumers SHALL follow `ensure-materialize-image` (t0 ensure already includes their hypo floors; a second `docker build` SHALL NOT run solely because the provider committed). Missing docker, failed ensure, token, or assets-path discovered only at this admit SHALL hard-fail the affected consumers and SHALL NOT roll back the provider’s already-committed overlay commit.

#### Scenario: Same-run bun-bin then ralph

- **WHEN** untargeted `update` commits a newer `dev-lang/bun-bin` PV and a withheld `dev-util/ralph-tui` would select a higher package PV under hypothetical bun-bin-at-remote ceilings
- **THEN** ralph-tui is admitted using that hypothetical working plan
- **AND** the program does not re-plan ralph-tui from committed bun-bin ebuilds solely because bun-bin committed

#### Scenario: Start-of-run skip is not terminal for withheld consumers

- **WHEN** ralph-tui’s on-disk-ceiling plan is a soft-skip because it already matches the start-of-run bun-bin ceiling, and bun-bin then commits a newer PV in the same run
- **THEN** ralph-tui’s working plan is the hypothetical plan
- **AND** ralph-tui is not left as a terminal skip solely due to the on-disk-ceiling plan

#### Scenario: Re-ensure before ralph materialize

- **WHEN** bun-bin has committed, ralph-tui’s hypothetical plan needs full-path work, and t0 ensure already satisfied those bun floors
- **THEN** ralph-tui may start container materialize without a second `docker build` solely because bun-bin committed
- **AND** a failed image at admit hard-fails ralph-tui without rolling back bun-bin

### Requirement: Provider hard-fail fails dependents

When an overlay wait-edge provider that was withholding consumers hard-fails (including half-applied GitMv before a signed overlay commit), the program SHALL NOT admit those consumers, SHALL NOT apply those consumers under the on-disk-ceiling plan or the hypothetical working plan, and SHALL hard-fail each withheld consumer with a message that names the provider. Other selected packages without that unmet predecessor MAY continue.

#### Scenario: bun-bin hard-fail does not apply ralph under old ceiling

- **WHEN** bun-bin hard-fails during apply and ralph-tui was withheld on bun-bin
- **THEN** ralph-tui hard-fails naming bun-bin
- **AND** ralph-tui is not mutated using the on-disk-ceiling plan or the hypothetical working plan

### Requirement: Unselected provider refuse is plan-delta

When a selected consumer has an overlay wait-edge provider that is **not** in this `update` selection, the program SHALL NOT add that provider to the selection. The program SHALL fetch (or use a valid check-cache latest payload for) that provider’s GitMv remote latest, even though the provider is unselected.

**Plan-delta** holds when the consumer’s runtime-lane planned unique PV set or needs-work determination under **hypothetical** overlay ceilings differs from the result under on-disk overlay ceilings. Hypothetical overlay ceilings SHALL be those ceiling discovery would compute from the current overlay provider package if the newest non-live provider ebuild’s version were the provider’s remote latest and that ebuild’s KEYWORDS were unchanged.

- When plan-delta holds, the consumer SHALL hard-fail (refuse) without overlay mutation. The message SHALL name the provider and SHALL mention recovery by updating that provider or running untargeted `update`.
- When plan-delta does not hold, the consumer MAY be planned and applied against on-disk overlay ceilings.
- When the provider latest-fetch (and check-cache latest lookup) fails so plan-delta cannot be evaluated, the consumer SHALL hard-fail (**fail-closed**). The message SHALL name the provider and SHALL indicate that its upstream latest could not be checked. The program SHALL NOT apply the on-disk-ceiling plan in that case.

Other selected packages SHALL continue. Soft-skip SHALL NOT be used for refuse or fail-closed: a run that targeted only the consumer SHALL exit with status `1`.

#### Scenario: Targeted ralph refuses while bun-bin is stale

- **WHEN** the user runs `update dev-util/ralph-tui`, bun-bin is not selected, bun-bin’s remote latest is newer than on-disk, and ralph-tui’s plan under hypothetical bun-bin-at-remote ceilings would select a different unique PV set than under on-disk ceilings
- **THEN** ralph-tui hard-fails naming bun-bin
- **AND** no ralph-tui overlay mutation occurs

#### Scenario: No plan-delta allows on-disk apply

- **WHEN** the user runs `update dev-util/ralph-tui`, bun-bin is not selected, bun-bin is outdated, and ralph-tui’s planned unique PVs and needs-work would be the same under hypothetical remote bun-bin ceilings
- **THEN** ralph-tui may apply against on-disk bun-bin ceilings

#### Scenario: Provider latest fetch fail-closed

- **WHEN** the user runs `update dev-util/ralph-tui`, bun-bin is not selected, and bun-bin’s remote latest cannot be obtained
- **THEN** ralph-tui hard-fails naming bun-bin
- **AND** the message indicates the provider upstream could not be checked
- **AND** ralph-tui is not applied under on-disk ceilings

#### Scenario: Selection is not auto-expanded

- **WHEN** the user runs `update dev-util/ralph-tui` and bun-bin is outdated
- **THEN** the run does not apply `dev-lang/bun-bin`
