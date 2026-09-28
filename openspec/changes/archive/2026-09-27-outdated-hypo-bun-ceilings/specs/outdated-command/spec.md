# Spec Delta

## MODIFIED Requirements

### Requirement: Outdated consumer line indicates overlay provider block

When `outdated` checks a `DepsAndAssets` package that has an overlay wait-edge provider as specified by `overlay-apply-waves`, the program SHALL evaluate plan-delta using the same hypothetical overlay ceilings and provider latest-fetch rules as `update` refuse (including check-cache for the provider's latest payload when valid). After a successful provider latest-fetch, the program SHALL compute hypothetical overlay ceilings and compare them to on-disk overlay ceilings from the same provider package. When the two ceiling results are equal, plan-delta does not hold. In that case the program SHALL NOT re-list upstream package versions or re-probe per-PV upstream metadata solely to evaluate plan-delta, and SHALL NOT print a provider-refuse line for the consumer. When the two ceiling results differ, the program SHALL evaluate plan-delta by planning the consumer against the hypothetical ceilings as already specified for `update` refuse. The program SHALL NOT store that hypothetical plan as a check-cache deps payload, as specified by `check-cache`.

The provider is in the `outdated` check set when the resolved selection contains that provider package key (including an untargeted `outdated`, which checks every discovered package). The provider is GitMv-outdated when the fetched remote latest is strictly greater than the newest non-live on-disk provider PV. That comparison SHALL use this provider latest fetch and SHALL NOT wait on the provider package's own outdated result.

When the provider is in the check set and GitMv-outdated and plan-delta holds, the program SHALL emit the consumer's runtime-lane gap lines for the hypothetical working plan, using the same lane-line rules as an on-disk gap (including `[assets reusable]` only when that plan's PV qualifies). The program SHALL NOT emit the on-disk plan's gap lines in their place, and SHALL NOT collapse several hypothetical lane gaps into one line that names only the highest PV. The program SHALL NOT append a provider-refuse line. When that hypothetical plan has no runtime-lane gap lines and ebuild-removal reporting has no removal lines, the program SHALL print no stdout line for the consumer.

When the provider is not in the check set and plan-delta holds, the program SHALL emit those same hypothetical gap lines, then exactly one further stdout line of the form `category/package: <refuse message>`, where `<refuse message>` is the unselected-provider refuse message specified by `overlay-apply-waves` (it names the provider and tells the operator to update that provider or run untargeted `update`). That refuse line SHALL be the consumer's only stdout line when the hypothetical plan has no gap lines and no removal lines. Consumer stdout for this check SHALL NOT contain the words "blocked on". The refuse line SHALL NOT by itself make `outdated` exit non-zero.

When the provider is in the check set and is not GitMv-outdated, the program SHALL emit the on-disk plan's gap lines and SHALL NOT print a provider-refuse line, including when the fetched remote latest is older than the on-disk provider PV.

When the provider is in the check set and is itself GitMv-outdated, that provider SHALL still produce its own unlabeled `LOCAL -> REMOTE` line. When the provider is not in the check set, the program SHALL still latest-check the provider for plan-delta. Provider latest-fetch failure SHALL NOT omit the consumer as current: the consumer SHALL hard-fail that package check or emit an error-class report that names the provider (fail-closed), matching `overlay-apply-waves` fail-closed policy, and SHALL NOT print an ordinary up-to-date omission for that consumer.

`outdated` SHALL NOT create an overlay git commit and SHALL NOT start a materialize-image build while producing these lines.

#### Scenario: Selected bun-bin prints the hypothetical ralph lines

- **WHEN** `outdated` includes `dev-lang/bun-bin` and `dev-util/ralph-tui`, bun-bin's remote latest is strictly greater than the on-disk bun-bin PV, on-disk ceilings would keep ralph-tui at an installed PV, and hypothetical ceilings would select a newer ralph-tui PV on one or more lanes
- **THEN** stdout includes a ralph-tui lane line for each such hypothetical gap, naming the bun-bin lane
- **AND** those lines do not contain "blocked on"
- **AND** stdout does not contain a `dev-util/ralph-tui:` refuse line
- **AND** stdout does not contain the on-disk plan's gap in place of the hypothetical gap

#### Scenario: Several hypothetical lanes stay several lines

- **WHEN** `outdated` includes bun-bin and ralph-tui, bun-bin is GitMv-outdated, and the hypothetical plan has two unsatisfied lanes with different target PVs
- **THEN** stdout includes two ralph-tui lane lines, one per lane
- **AND** stdout does not replace them with a single line whose only label is a provider block

#### Scenario: Satisfied hypothetical plan prints nothing for the consumer

- **WHEN** `outdated` includes bun-bin and ralph-tui, bun-bin is GitMv-outdated, plan-delta holds because the on-disk plan needs work, and the hypothetical plan has no lane gap and would delete no ebuild
- **THEN** stdout has no ralph-tui line
- **AND** bun-bin still prints its unlabeled `LOCAL -> REMOTE` line when bun-bin itself is GitMv-outdated

#### Scenario: Bun-bin still has its own outdated line when checked

- **WHEN** `outdated` includes both `dev-lang/bun-bin` and `dev-util/ralph-tui` and bun-bin is GitMv-outdated with ralph plan-delta
- **THEN** stdout includes bun-bin's unlabeled `LOCAL -> REMOTE` line
- **AND** ralph-tui's lines do not contain "blocked on"

#### Scenario: Left-out bun-bin prints hypothetical lines and one refuse line

- **WHEN** `outdated` checks `dev-util/ralph-tui`, bun-bin is not in the check set, bun-bin's remote latest would change the ceilings, and the hypothetical plan selects a newer ralph-tui PV
- **THEN** stdout includes the hypothetical ralph-tui lane line
- **AND** stdout includes exactly one line that starts with `dev-util/ralph-tui:` and is the unselected-provider refuse message for `dev-lang/bun-bin`, including recovery by updating that provider or running untargeted `update`
- **AND** the command exits `0` when no spine hard failure occurred

#### Scenario: Left-out plan-delta with nothing to print still refuses

- **WHEN** `outdated` checks `dev-util/ralph-tui`, bun-bin is not in the check set, plan-delta holds, and the hypothetical plan has no lane gap and would delete no ebuild
- **THEN** stdout for ralph-tui is only the `dev-util/ralph-tui:` refuse line naming `dev-lang/bun-bin`
- **AND** the program does not omit ralph-tui as current

#### Scenario: Provider already current uses on-disk lines

- **WHEN** `outdated` includes bun-bin and ralph-tui and bun-bin's remote latest is not strictly greater than the on-disk bun-bin PV
- **THEN** ralph-tui stdout follows the on-disk plan
- **AND** stdout does not contain a `dev-util/ralph-tui:` refuse line

#### Scenario: Ralph line indicates blocked on bun-bin

- **WHEN** `outdated` checks `dev-util/ralph-tui` without `dev-lang/bun-bin` in the check set, on-disk bun-bin ceilings keep ralph-tui at a PV already present, bun-bin remote latest would raise the ceiling, and ralph-tui would select a newer PV under hypothetical ceilings
- **THEN** stdout includes the hypothetical ralph-tui lane line and exactly one `dev-util/ralph-tui:` refuse line naming `dev-lang/bun-bin`
- **AND** those lines do not contain "blocked on"
- **AND** the program does not treat ralph-tui as having no outdated output solely because the on-disk plan matches local ebuilds

#### Scenario: Equal ceilings do not indicate blocked-on

- **WHEN** `outdated` checks `dev-util/ralph-tui` and bun-bin's remote latest yields hypothetical overlay ceilings equal to on-disk bun-bin ceilings
- **THEN** ralph-tui stdout does not contain "blocked on" and does not contain a provider-refuse line
- **AND** the program does not re-list ralph-tui upstream versions or re-probe per-PV metadata solely to evaluate plan-delta

#### Scenario: Provider latest failure does not look current

- **WHEN** `outdated` checks `dev-util/ralph-tui` and bun-bin's upstream latest cannot be fetched
- **THEN** the ralph-tui check emits an error-class report that names `dev-lang/bun-bin`
- **AND** stdout does not omit ralph-tui as an ordinary up-to-date package

#### Scenario: Outdated does not commit or build

- **WHEN** `outdated` includes bun-bin and ralph-tui and prints ralph-tui's hypothetical gap lines
- **THEN** the program does not create an overlay git commit
- **AND** the program does not start a materialize-image build

## ADDED Requirements

### Requirement: Outdated reports ebuild removals apply would perform

For each `DepsAndAssets` package, after the runtime-lane gap lines of the plan this check is displaying (the hypothetical working plan when `outdated-command` selects that plan, otherwise the on-disk plan), the program SHALL print one removal line per non-live PV that `update` of that package alone would delete. A PV is a removal candidate when it is a non-live local PV absent from that plan's unique PV set. The program SHALL omit a candidate that overlay-internal atom closure would keep because another on-disk ebuild still requires it, using on-disk ebuilds only and not a same-run plan of other packages. Each removal line SHALL have the form `category/package PV -> removed`, with `PV` in pretty form without a leading `v` and without a revision suffix. Multiple revisions of one PV SHALL produce one line. Removal lines SHALL NOT include a lane label or an assets marker. Removal lines SHALL follow the gap lines and SHALL precede a provider-refuse line when that line is emitted, in ascending PV order.

`GitMvAndManifest` packages SHALL NOT gain `-> removed` lines because older ebuilds remain beside the newest ebuild.

When the displayed plan has at least one removal candidate and the keep decision cannot be read or parsed, the program SHALL emit an error-class report for that package, SHALL NOT print a removal line for it, and SHALL still emit any lane gap lines and provider-refuse line that the displayed plan otherwise requires.

#### Scenario: Prune-only package prints a removal line

- **WHEN** a `DepsAndAssets` package's displayed plan selects only an installed PV and another non-live local PV is absent from that plan and no on-disk ebuild requires the absent PV
- **THEN** stdout includes `category/package PV -> removed` for the absent PV
- **AND** the program does not omit the package as current

#### Scenario: Pinned PV is not reported removed

- **WHEN** the displayed plan's unique set omits `6.6.1` and a remaining on-disk ebuild still requires that PV
- **THEN** stdout does not include a `6.6.1 -> removed` line for that package

#### Scenario: Removals follow gaps and precede the refuse line

- **WHEN** `outdated` checks a Bun consumer whose hypothetical plan has a lane gap and a removable local PV, and the provider is not in the check set so a refuse line is emitted
- **THEN** the lane gap line appears before the `PV -> removed` line
- **AND** the `PV -> removed` line appears before the `category/package:` refuse line

#### Scenario: Keep-set failure does not guess a removal

- **WHEN** the displayed plan has a removal candidate and the keep decision fails
- **THEN** the package check emits an error-class report
- **AND** stdout does not include a `-> removed` line for that package

#### Scenario: GitMv bun-bin does not use removal lines

- **WHEN** `outdated` checks `dev-lang/bun-bin` and the package directory still contains an older compile-pin ebuild beside the newest ebuild
- **THEN** stdout does not include a `dev-lang/bun-bin <PV> -> removed` line for that older ebuild
