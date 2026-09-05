## ADDED Requirements

### Requirement: Atom-closure overlay-write wait is visible

When activity indicators are enabled and a package is waiting for an overlay-internal atom-closure provider before overlay mutation, as specified by `overlay-atom-closure`, the apply multi-progress row for that package SHALL use waiting presentation naming the provider. That wait SHALL NOT occupy a package job slot. The program SHALL NOT open a second apply panel solely for this wait. Ceiling wait-edge withhold presentation specified for `overlay-apply-waves` SHALL remain unchanged: a Cargo package waiting only on atom closure MAY already be in-flight for language materialize, then show waiting when blocked on overlay write.

#### Scenario: hk waits on usage at overlay write

- **WHEN** indicators are enabled, untargeted `update` is applying usage and hk, and hk overlay mutation is waiting because current usage PVs would not satisfy hk’s to-be-written ebuild
- **THEN** the hk row uses waiting presentation naming `dev-util/usage`
- **AND** there is not a second apply panel solely for that wait

#### Scenario: Atom-closure wait is not Graph 1 withhold of mise

- **WHEN** mise’s to-be-written ebuild is already atom-closed against on-disk usage
- **THEN** mise is not shown as waiting on `dev-util/usage` solely because usage is also in the selection
