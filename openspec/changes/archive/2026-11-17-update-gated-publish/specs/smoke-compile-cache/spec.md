# Spec Delta

## MODIFIED Requirements

### Requirement: Compile cache cleanup at start

At the start of every `smoke` command that uses the compile cache, and of every `update` command that will run gated smoke runs with the compile cache, the program SHALL remove, in order, before the first run: caches of packages no longer in the overlay inventory; caches unused for 30 days; then the least recently used packages' caches until the total fits the budget. In kept caches it SHALL delete Go and Zig entries unused for 30 days.

#### Scenario: Package removed from the overlay

- **WHEN** `dev-util/old` is no longer in the overlay and its cache exists
- **THEN** its cache is removed before the first run

#### Scenario: Over budget

- **WHEN** the caches total 4 GiB and the budget is 3 GiB
- **THEN** whole package caches are removed, least recently used first, until the total is at most 3 GiB

#### Scenario: Update cleans before its first gate

- **WHEN** `update` will gate at least one unit with the compile cache
- **THEN** cleanup runs before that unit's first gated run

### Requirement: Running without a compile cache

With `--no-compile-cache` on `smoke` or `update`, smoke runs SHALL NOT mount the compile cache volume and SHALL build with ccache disabled and with the Go, configure, and Zig caches left at Portage's per-build defaults. Cleanup SHALL NOT run.

#### Scenario: Opt-out run

- **WHEN** the operator runs `smoke --no-compile-cache crush`
- **THEN** the run container has no `mndz-smoke-compile-cache` mount
- **AND** the build performs no ccache lookups

#### Scenario: Update opt-out

- **WHEN** the operator runs `update --no-compile-cache crush`
- **THEN** the gated run containers have no `mndz-smoke-compile-cache` mount and no cleanup runs
