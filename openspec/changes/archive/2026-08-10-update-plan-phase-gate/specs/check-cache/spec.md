## ADDED Requirements

### Requirement: Update opens check cache before plan phase

On `update`, when the check cache is enabled or `--refresh` forces live work with write-back enabled, the program SHALL open the check-cache handle **before** the plan phase that determines needs-work, so plan can record hits and fetches and store successful live plans. The program SHALL NOT defer opening the check cache until after the disk-space feasibility gate.

#### Scenario: Cache available during plan

- **WHEN** the user runs `update` with the check cache enabled
- **THEN** plan-phase lookups and stores can use the open cache before package mutation begins

## MODIFIED Requirements

### Requirement: One info summary of hits and fetches

At the end of an `outdated` or `update` run that performs package check or plan work with the cache enabled or refresh forced, the program SHALL log exactly one informational summary that reports how many packages used a valid cache hit and how many performed live fetch or plan network work (for example hit and fetch counts). The program SHALL NOT be required to log per-package hit or miss at info level. For `update`, plan-phase and mutate-phase cache traffic SHALL be included in that single end-of-run summary (not one summary per phase).

#### Scenario: Summary after mixed run

- **WHEN** a run uses valid cache entries for some packages and live network for others
- **THEN** one info log line (or equivalent single info message) reports both hit and fetch counts

#### Scenario: Update plan and mutate one summary

- **WHEN** `update` records cache hits during plan and additional fetches during the same run
- **THEN** exactly one hit/fetch summary is emitted for the run
