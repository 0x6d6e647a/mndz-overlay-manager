# Spec Delta

## MODIFIED Requirements

### Requirement: One fresh container per run

Each run SHALL use a new container created from the smoke image and SHALL remove it when the run ends, whatever the outcome. No state inside a container SHALL carry over to another run except the binary-package and dependency-distfiles volumes and the package's compile cache (see `smoke-compile-cache`). Containers SHALL carry the product and run labels used for materialize sessions and a name beginning `mndz-smoke-<run-id>-`.

#### Scenario: Failed run leaves no container

- **WHEN** a run fails in a check
- **THEN** its container no longer exists when the next run starts

#### Scenario: Previous install is not visible

- **WHEN** the run for `dev-util/beads-1.0.4` has finished and the run for `dev-util/beads-1.3.4` starts
- **THEN** no `dev-util/beads` version is installed in the new container before its emerge

#### Scenario: Compile cache carries over

- **WHEN** the run for `dev-util/beads-1.0.4` has finished and the run for `dev-util/beads-1.3.4` starts with the compile cache on
- **THEN** the new container sees the compile cache written by the earlier run

## ADDED Requirements

### Requirement: Compile cache volume is kept by eclean

`eclean` SHALL NOT remove or prune the `mndz-smoke-compile-cache` volume. Removing the whole volume SHALL be a manual operator action.

#### Scenario: Eclean leaves the volume

- **WHEN** the operator runs `eclean`
- **THEN** `mndz-smoke-compile-cache` and its contents are unchanged
