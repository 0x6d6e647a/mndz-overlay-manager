# Spec Delta

## ADDED Requirements

### Requirement: Smoke compile cache statistics are recorded

When recording, each smoke run that used the compile cache SHALL record its ccache hits and misses, the number of Go cache entries it added, and the result of a Go trim check when one ran. Each smoke command SHALL record the compile cache size before and after cleanup and the number of package caches removed.

#### Scenario: Run statistics

- **WHEN** the run of `dev-util/crush-0.101.0` finishes with the compile cache on while recording
- **THEN** the run metrics for that run contain its ccache hit and miss counts and its Go cache entries added

#### Scenario: Failed trim check is recorded

- **WHEN** the Go trim check fails during a recorded smoke command
- **THEN** the run metrics record the failed check and the Go version it ran with

#### Scenario: Opt-out run

- **WHEN** the operator runs `smoke --no-compile-cache` while recording
- **THEN** no compile cache statistics are recorded for its runs
