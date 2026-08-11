## ADDED Requirements

### Requirement: Outdated and update help document refresh and check cache

Per-command help for `outdated` and `update` SHALL document the `--refresh` flag as forcing a live outdated check or plan that ignores the check cache for reads. Command-scoped help or footers SHALL NOT claim that `outdated` has no subcommand-local flags when `--refresh` exists. Help text MAY briefly note that successful checks are cached for a configurable TTL to reduce repeated network work.

#### Scenario: Outdated help mentions refresh

- **WHEN** the user runs `outdated --help`
- **THEN** the usage text describes `--refresh`
- **AND** the program exits with status `0` without loading configuration

#### Scenario: Update help mentions refresh

- **WHEN** the user runs `update --help`
- **THEN** the usage text describes `--refresh`
- **AND** the program exits with status `0` without loading configuration
