# Spec Delta

## MODIFIED Requirements

### Requirement: Waits for parallel slots are spans

Each wait for a package job slot, a nested work-budget slot, the shared pack compression slot, the `update` smoke lane, or an overlay dependency at a gate SHALL be recorded as a span named `slot.wait`. Its attrs SHALL name the slot kind and its capacity, and the span SHALL end when the slot is acquired or the wait ends. The kinds for the smoke lane and dependency waits SHALL be `smoke` and `gate-dependency`. A `gate-dependency` wait SHALL name the dependency package.

#### Scenario: Pack slot contention is visible

- **WHEN** two units are ready to pack at the same time during `update`
- **THEN** one unit has a `slot.wait` span with kind `pack` whose duration covers the other unit's compression

#### Scenario: Smoke lane wait is visible

- **WHEN** two units reach their gates at the same time during `update`
- **THEN** one unit has a `slot.wait` span with kind `smoke` whose duration covers the other unit's gated runs

#### Scenario: Dependency wait is visible

- **WHEN** `codex-acp` waits at its gate for `dev-util/codex`
- **THEN** `codex-acp` has a `slot.wait` span with kind `gate-dependency` that names `dev-util/codex`

## ADDED Requirements

### Requirement: Smoke runs record disk use

When recording, each smoke run, standalone or gated, SHALL record the Portage build-directory size of every package it builds at the end of that package's install phase, the container's writable-layer size before removal, and the package step's distfiles size. An unreadable value SHALL be recorded as its reason. Measuring SHALL NOT change a run's outcome or disable a Portage sandbox.

#### Scenario: Build directory peak per package

- **WHEN** a run builds `dev-libs/foo` in its dependencies step and `dev-util/hk-2.13.0` in its package step while recording
- **THEN** the run records a build-directory peak for each of the two packages

#### Scenario: Writable layer at teardown

- **WHEN** a smoke container is removed after its run
- **THEN** its writable-layer size, or the reason it could not be read, is recorded

#### Scenario: No-metrics run measures nothing

- **WHEN** the operator runs `--no-metrics smoke`
- **THEN** no disk measurement is taken inside the containers

### Requirement: Gated runs are recorded under their unit

When recording, each gated run of `update` SHALL be recorded as a span under the unit's package span. The span SHALL carry the package, the PV, and the lane label when the run has one. When the gate ends, the span SHALL record the stage the run reached and the gate outcome. The run's measured commands and disk use SHALL be recorded under that span as for `smoke`.

#### Scenario: Gate span nests

- **WHEN** `update` gates `dev-util/hk-2.13.0` while recording
- **THEN** the gated run's span has the `dev-util/hk` package span as an ancestor and records the gate outcome
