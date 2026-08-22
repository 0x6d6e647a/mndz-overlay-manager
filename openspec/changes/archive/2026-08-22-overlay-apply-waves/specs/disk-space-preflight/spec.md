## ADDED Requirements

### Requirement: Disk gate re-runs for units discovered after overlay re-plan

When `update` re-plans withheld overlay wait-edge consumers after a provider signed commit and that re-plan introduces needs-work heavy units that were not included in the previous disk-space feasibility gate, the program SHALL evaluate the disk-space gate for those **new** units before those units mutate, using the same reuse versus full classification and needs-work-only rules as the initial gate. Insufficient free space at that re-entry SHALL hard-fail the affected consumers (or the command when the gate is command-level for those units) and SHALL NOT roll back already-committed overlay units. Units already gated and admitted SHALL NOT be required to pass a second gate solely because a sibling consumer was re-planned.

#### Scenario: Ralph full-path need gated after bun-bin commit

- **WHEN** the initial gate ran with no ralph-tui heavy units because ralph-tui was a start-of-run skip, bun-bin then committed, and ralph-tui re-plan needs full-path materialize
- **THEN** free-space feasibility is evaluated for that ralph-tui unit before ralph-tui mutate
- **AND** bun-bin’s overlay commit is not reverted if that gate fails
