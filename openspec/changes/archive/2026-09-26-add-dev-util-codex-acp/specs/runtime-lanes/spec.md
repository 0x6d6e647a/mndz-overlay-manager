# Spec Delta

## ADDED Requirements

### Requirement: codex-acp nodejs lanes are amd64 only

Policy for `dev-util/codex-acp` SHALL allowlist `amd64` only. When that package is planned, the planner SHALL create nodejs lanes only for amd64. When amd64 has a target, planned `KEYWORDS` SHALL be `-* ~amd64`. Arches outside the allowlist SHALL NOT receive lane targets and SHALL NOT appear in planned `KEYWORDS`.

#### Scenario: arm64 nodejs is excluded

- **WHEN** `dev-util/codex-acp` is planned and gentoo `net-libs/nodejs` also keywords `arm64`
- **THEN** no arm64 lane target is produced
- **AND** planned `KEYWORDS` are `-* ~amd64` and do not include `~arm64`
