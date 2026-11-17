# Spec Delta

## ADDED Requirements

### Requirement: Smoke container commands are measured

When recording, each emerge step and each check command that `smoke` runs in a container SHALL be measured like a materialize container command: the host `docker exec` invocation (`.outer`) and the command inside the container (`.inner`) under one parent span that names the container. Each run SHALL have a span naming the ebuild atom and lane label, and each container SHALL have a `container` resource event before it is removed.

#### Scenario: Emerge step pair

- **WHEN** `smoke` runs the package step for `dev-util/crush-0.101.0` while recording
- **THEN** the run has a `.outer` result for the `docker exec` and an `.inner` result for `emerge`, both under the span for that smoke run

#### Scenario: Container snapshot

- **WHEN** a smoke container is removed after its run
- **THEN** a `container` event for it records CPU microseconds and peak memory bytes, or the reason they could not be read

#### Scenario: No-metrics run

- **WHEN** the operator runs `--no-metrics smoke`
- **THEN** commands in the container are not wrapped with GNU time and no run metrics directory is created

## MODIFIED Requirements

### Requirement: Work commands record a run by default

When the operator runs `outdated`, `update`, `gencache`, `smoke`, or `eclean` without `--no-metrics`, the program SHALL record that run to a run metrics directory. `list` and `github-token` SHALL NOT record a run.

#### Scenario: Update records a run

- **WHEN** the operator runs `update` with no `--no-metrics`
- **THEN** a new run metrics directory exists after the command finishes
- **AND** it contains a `run.jsonl` file for that run

#### Scenario: Smoke records a run

- **WHEN** the operator runs `smoke` with no `--no-metrics`
- **THEN** a new run metrics directory whose name ends in `-smoke` exists after the command finishes

#### Scenario: List does not record

- **WHEN** the operator runs `list`
- **THEN** no run metrics directory is created for that invocation
