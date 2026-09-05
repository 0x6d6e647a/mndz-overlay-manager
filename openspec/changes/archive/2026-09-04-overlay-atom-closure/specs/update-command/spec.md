## ADDED Requirements

### Requirement: Unselected provider atom-closure refuse

When a selected `update` package would overlay-mutate an ebuild whose overlay-internal atoms are unsatisfied, and the provider is **not** in this `update` selection (or is selected but its planned remaining PVs still would not satisfy), the program SHALL hard-fail that package as specified by `overlay-atom-closure` without adding the provider to the selection. Other selected packages SHALL continue. A run that targeted only that consumer SHALL exit with status `1`. Soft-skip SHALL NOT be used for this refuse.

#### Scenario: Targeted hk refuses while usage cannot satisfy

- **WHEN** the user runs `update dev-util/hk`, usage is not selected, and hk’s to-be-written ebuild has an overlay-internal usage atom that overlay usage PVs do not satisfy
- **THEN** hk hard-fails naming `dev-util/usage`
- **AND** the run does not apply `dev-util/usage`
- **AND** the command exits with status `1`

#### Scenario: Already-satisfiable targeted hk proceeds

- **WHEN** the user runs `update dev-util/hk` and hk’s to-be-written ebuild’s overlay-internal atoms are satisfied by on-disk provider PVs
- **THEN** hk MAY overlay-mutate without waiting on an unselected provider
