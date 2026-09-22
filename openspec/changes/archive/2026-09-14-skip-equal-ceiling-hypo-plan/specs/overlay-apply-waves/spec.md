## MODIFIED Requirements

### Requirement: Unselected provider refuse is plan-delta

When a selected consumer has an overlay wait-edge provider that is **not** in this `update` selection, the program SHALL NOT add that provider to the selection. The program SHALL fetch (or use a valid check-cache latest payload for) that provider’s GitMv remote latest, even though the provider is unselected.

**Plan-delta** holds when the consumer’s runtime-lane planned unique PV set or needs-work determination under **hypothetical** overlay ceilings differs from the result under on-disk overlay ceilings. Hypothetical overlay ceilings SHALL be those ceiling discovery would compute from the current overlay provider package if the newest non-live provider ebuild’s version were the provider’s remote latest and that ebuild’s KEYWORDS were unchanged.

After a successful provider latest-fetch, the program SHALL compute those hypothetical overlay ceilings and compare them to on-disk overlay ceilings from the same provider package. When the two ceiling results are equal, plan-delta does not hold. In that case the program SHALL NOT re-list upstream package versions or re-probe per-PV upstream metadata solely to evaluate plan-delta. When the two ceiling results differ, the program SHALL evaluate plan-delta by planning the consumer against the hypothetical ceilings and comparing unique planned PVs and needs-work to the on-disk-ceiling plan, as already specified.

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

#### Scenario: Equal ceilings skip the hypothetical plan

- **WHEN** the user runs `update dev-util/ralph-tui`, bun-bin is not selected, and bun-bin’s remote latest yields hypothetical overlay ceilings equal to on-disk bun-bin ceilings
- **THEN** ralph-tui is not refused for plan-delta
- **AND** the program does not re-list ralph-tui upstream versions or re-probe per-PV metadata solely to evaluate plan-delta
- **AND** ralph-tui may apply against on-disk bun-bin ceilings

#### Scenario: Provider latest fetch fail-closed

- **WHEN** the user runs `update dev-util/ralph-tui`, bun-bin is not selected, and bun-bin’s remote latest cannot be obtained
- **THEN** ralph-tui hard-fails naming bun-bin
- **AND** the message indicates the provider upstream could not be checked
- **AND** ralph-tui is not applied under on-disk ceilings

#### Scenario: Selection is not auto-expanded

- **WHEN** the user runs `update dev-util/ralph-tui` and bun-bin is outdated
- **THEN** the run does not apply `dev-lang/bun-bin`
