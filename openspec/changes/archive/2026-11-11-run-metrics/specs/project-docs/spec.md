# Spec Delta

## ADDED Requirements

### Requirement: README documents run metrics

`README.md` SHALL document at operator depth: that `outdated`, `update`, `gencache`, and `eclean` record run metrics by default; the location `${XDG_STATE_HOME:-$HOME/.local/state}/mndz/overlay-manager/metrics/<run-id>-<command>/`; that runs are kept and never pruned; that GNU `/usr/bin/time` is required unless `--no-metrics` is given; and that `--no-metrics` logs a warning.

#### Scenario: Operator learns how to opt out

- **WHEN** an operator without GNU time reads `README.md`
- **THEN** it states that `/usr/bin/time` is required for work commands and that `--no-metrics` disables recording

#### Scenario: Operator finds run data

- **WHEN** an operator wants to inspect a past run
- **THEN** `README.md` names the metrics directory pattern and the `run.jsonl` file

### Requirement: CONTRIBUTING documents build identity

`CONTRIBUTING.md` SHALL document at contributor depth that binaries embed build identity for run metrics: that the build flavor comes from `scripts/with-flavor` and is `unknown` for builds outside it, that the git revision and dirty flag are captured at compile time and can be stale when a build is reported up to date, and that run headers carry the executable SHA-256 to detect that.

#### Scenario: Contributor sees a stale revision

- **WHEN** a contributor sees two runs with the same `git_rev` but different `exe_sha256`
- **THEN** `CONTRIBUTING.md` explains why the revision label can be stale
