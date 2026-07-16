# cli-concurrency Specification

## Purpose

Bounded package-level job pool (`--jobs`) shared by concurrent check and apply paths.

## Requirements

### Requirement: Global jobs flag

The CLI SHALL accept a global `--jobs N` option where `N` is a positive integer specifying the maximum number of concurrent package-level jobs. The option SHALL appear in top-level help.

#### Scenario: Explicit jobs limit

- **WHEN** the user runs a concurrent command with `--jobs 2`
- **THEN** at most two package-level jobs run at the same time

### Requirement: Default jobs is host processor count

When `--jobs` is omitted, the program SHALL use a default concurrency equal to the host processor count (equivalent to `nproc` / `getNumProcessors`).

#### Scenario: Default without flag

- **WHEN** the user runs `outdated` or `update` without `--jobs`
- **THEN** package-level concurrency is capped at the detected host processor count

### Requirement: Job pool applies to package checks and apply phase one

The jobs limit SHALL bound concurrent per-package work for `outdated` checks and for `update` phase-1 apply. The limit SHALL NOT force preflight steps or signed commits to run concurrently; those phases remain sequential.

#### Scenario: Commits remain sequential

- **WHEN** multiple packages succeed in update phase 1
- **THEN** signed commits still run one after another regardless of `--jobs`

#### Scenario: Outdated checks are concurrent under the limit

- **WHEN** the user runs `outdated` with multiple packages and `--jobs 4`
- **THEN** package update checks may proceed concurrently with at most four in flight
