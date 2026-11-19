# Spec Delta

## MODIFIED Requirements

### Requirement: Event file is JSON Lines with a schema version

`run.jsonl` SHALL contain one JSON object per line. Every object SHALL have an `ev` field naming the event kind (`run_start`, `span_start`, `span_end`, `sample`, `container`, `priority`, `run_end`). Every object except `run_start` SHALL have `t_ns`, the monotonic nanoseconds since the run started. The `run_start` line SHALL be first and SHALL carry `schema`, an integer format version.

#### Scenario: First line is the header

- **WHEN** a recorded run's `run.jsonl` is read
- **THEN** its first line has `"ev":"run_start"` and an integer `schema`
- **AND** every other line has an `ev` and a non-negative integer `t_ns`

#### Scenario: Unknown fields are additive

- **WHEN** a later build adds a new span name or a new attribute to an existing event
- **THEN** `schema` does not change

#### Scenario: Priority event is additive

- **WHEN** a recorded run includes a `priority` event
- **THEN** `schema` is the same as for runs without one

## ADDED Requirements

### Requirement: Applied process priority is recorded

When the manager applies its effective priority, a recorded run SHALL contain one `priority` event. The event SHALL give the requested nice and I/O priority (absent when unset), the effective nice and I/O priority, and whether the floor kept an inherited value for each.

#### Scenario: Floored nice is recorded

- **WHEN** the operator runs `update --nice 10` from a shell at nice 15
- **THEN** the `priority` event records requested nice 10, effective nice 15, and that the nice floor applied

#### Scenario: Unset priority is recorded

- **WHEN** the operator runs `update` with no priority options or keys from a shell at nice 0
- **THEN** the `priority` event records no requested values and effective nice 0
