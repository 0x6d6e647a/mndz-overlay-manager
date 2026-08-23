## MODIFIED Requirements

### Requirement: Re-plan consumers after provider signed commit

After an overlay wait-edge provider in this run creates a successful signed overlay commit, the program SHALL rediscover that provider’s overlay runtime ceilings from the committed overlay disk (not from a start-of-run in-memory ceiling snapshot) and SHALL re-plan each withheld consumer using those ceilings. Re-plan SHALL honor the check cache only when the consumer’s deps fingerprint matches, including the overlay ceiling-provider package fingerprint specified by `check-cache`. After re-plan, the program SHALL classify reuse versus full, evaluate conditional `update` preflight, **ensure the materialize image** as specified by `ensure-materialize-image` when new units are full path, and run the disk-space gate for any **new** needs-work heavy units before admitting those consumers to language materialize, as specified by `update-command` and `disk-space-preflight`. Missing docker, failed ensure, token, or assets-path discovered only at this re-entry SHALL hard-fail the affected consumers and SHALL NOT roll back the provider’s already-committed overlay commit.

#### Scenario: Same-run bun-bin then ralph

- **WHEN** untargeted `update` commits a newer `dev-lang/bun-bin` PV and a withheld `dev-util/ralph-tui` would select a higher package PV under the new overlay bun-bin ceilings
- **THEN** ralph-tui is re-planned against the committed bun-bin ebuilds
- **AND** that higher PV may be applied in the same `update` run

#### Scenario: Start-of-run skip is not terminal for withheld consumers

- **WHEN** ralph-tui’s initial plan is a soft-skip because it already matches the start-of-run bun-bin ceiling, and bun-bin then commits a newer PV in the same run
- **THEN** ralph-tui is re-planned and is not left as a terminal skip solely due to the initial plan

#### Scenario: Re-ensure before ralph materialize

- **WHEN** bun-bin has committed, ralph-tui re-plan needs full-path work, and the current materialize image does not satisfy the new Bun floor
- **THEN** ensure runs before ralph-tui container materialize
- **AND** a failed ensure hard-fails ralph-tui without rolling back bun-bin
