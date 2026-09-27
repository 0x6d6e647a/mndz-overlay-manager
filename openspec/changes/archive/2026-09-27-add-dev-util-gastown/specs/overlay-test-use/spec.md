# overlay-test-use Specification

## MODIFIED Requirements

### Requirement: Go packages with existing suites are USE-gated

`dev-db/dolt`, `dev-util/beads`, `dev-util/crush`, and `dev-util/gastown` SHALL each declare `IUSE` including `test`, set `RESTRICT` including `!test? ( test )`, retain a `src_test` that runs the package Go tests (`ego test` or equivalent), and publish content-only gate fixes as revision bumps. For `dev-util/gastown`, `src_test` SHALL run the Go tests in short mode.

#### Scenario: dolt gated

- **WHEN** the live dolt ebuild is inspected
- **THEN** it includes `test` in `IUSE` and `!test? ( test )` in `RESTRICT`
- **AND** `src_test` still runs Go tests
- **AND** the ebuild filename reflects a revision bump when the gate was introduced as content-only relative to an unrevised prior live file

#### Scenario: beads and crush gated

- **WHEN** the live beads and crush ebuilds are inspected
- **THEN** each satisfies the same IUSE, RESTRICT, `src_test`, and revision rules as dolt

#### Scenario: gastown gated

- **WHEN** the live gastown ebuild is inspected
- **THEN** it includes `test` in `IUSE` and `!test? ( test )` in `RESTRICT`
- **AND** `src_test` runs the Go tests in short mode
- **AND** an initial ebuild that already contains the gate is compliant without a revision bump solely for that gate
