# Spec Delta

## MODIFIED Requirements

### Requirement: Selected provider needs-work uses hypothetical ceilings as the working plan

When an overlay wait-edge provider is **in this `update` selection** and its plan is needs-work (GitMv local PV strictly less than remote latest), every selected consumer of that provider SHALL be planned against **hypothetical** overlay ceilings: ceiling discovery as if the newest non-live provider ebuild’s version were that provider’s remote latest and that ebuild’s KEYWORDS were unchanged (the same construction specified for unselected plan-delta). That hypothetical plan SHALL be the consumer’s **working plan** for classify, needs-work, materialize-image floors, and apply. The program SHALL NOT use the start-of-run on-disk provider ceiling plan as the working plan for those consumers, and SHALL NOT rediscover ceilings from overlay disk and re-plan those consumers after the provider’s signed overlay commit.

Unselected-provider plan-delta refuse and fail-closed SHALL remain as already specified. When `outdated` prints these hypothetical ceilings, it SHALL follow `outdated-command`.

#### Scenario: Untargeted update plans ralph against bun-bin remote

- **WHEN** untargeted `update` selects bun-bin and ralph-tui, on-disk bun-bin is `1.3.14`, bun-bin remote latest is `1.4.0`, and ralph-tui’s unique PV set under bun-bin `1.4.0` ceilings differs from the on-disk `1.3.14` ceilings
- **THEN** ralph-tui’s working plan is the `1.4.0` hypothetical plan
- **AND** the program does not apply the `1.3.14` on-disk-ceiling plan for ralph-tui

#### Scenario: Provider already current uses on-disk ceilings

- **WHEN** bun-bin is selected and the initial plan soft-skips it as already at latest
- **THEN** selected Bun consumers are planned against on-disk bun-bin ceilings
- **AND** hypothetical-at-remote is not the working plan solely because bun-bin is in the selection

#### Scenario: Outdated is not excused from the working plan

- **WHEN** `outdated` includes `dev-lang/bun-bin` and `dev-util/ralph-tui`, bun-bin is GitMv-outdated, and ralph-tui’s plan under hypothetical ceilings differs from the on-disk plan
- **THEN** ralph-tui stdout is the hypothetical working plan’s lines as specified by `outdated-command`
- **AND** this requirement does not allow `outdated` to print only the on-disk ceiling plan for that consumer
