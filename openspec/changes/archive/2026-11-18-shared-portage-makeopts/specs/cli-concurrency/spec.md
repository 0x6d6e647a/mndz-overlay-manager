# CLI concurrency delta

## MODIFIED Requirements

### Requirement: Jobs sets build parallelism for smoke

For `smoke` and the gated runs of `update`, the resolved jobs value SHALL configure build parallelism as specified by `portage-build-parallelism`. Each smoke emerge SHALL run one package job at a time. Within one command, smoke runs and their workload containers SHALL remain sequential regardless of the jobs value.

#### Scenario: Explicit jobs

- **WHEN** the operator runs `--jobs 8 smoke crush`
- **THEN** the emerges in the container run with `MAKEOPTS="-j8 -l9"`
- **AND** each emerge runs with one package job

#### Scenario: Default jobs

- **WHEN** the operator runs `smoke` without `--jobs` on a host with 16 processors
- **THEN** the emerges run with `MAKEOPTS="-j16 -l17"`

#### Scenario: Runs stay sequential

- **WHEN** the operator runs `--jobs 4 smoke` with many packages selected
- **THEN** at most one smoke container exists at any time

#### Scenario: Update gates stay sequential

- **WHEN** the operator runs `--jobs 4 update` and several units reach their gates
- **THEN** at most one smoke container of that `update` exists at any time
