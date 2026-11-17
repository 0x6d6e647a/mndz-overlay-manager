# Spec Delta

## ADDED Requirements

### Requirement: Jobs sets build parallelism for smoke

For `smoke`, the resolved `--jobs` value `N` SHALL set the build parallelism inside each container as `MAKEOPTS="-j<N> -l<N+1>"`, and each emerge SHALL run one package job at a time. `--jobs` SHALL NOT cause more than one smoke run or more than one smoke container to be active at once.

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
