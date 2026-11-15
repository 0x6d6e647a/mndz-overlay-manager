# Spec Delta

## MODIFIED Requirements

### Requirement: Work budget for nested Go planning work

In addition to the package job limit, the program SHALL maintain a separate process-wide work budget for nested Go planning resource units with capacity equal to twice the resolved package jobs limit (`2 * jobs`, treating non-positive jobs as 1 before doubling). Package admission and the work budget SHALL use distinct concurrency limiters so nested work cannot deadlock against package slots.

The work budget SHALL gate at least: Go ceiling discovery (the managed-tree go ebuild scan for that discovery), listing upstream versions for a Go package plan, and each go.mod fetch performed for version candidates. At most `2 * jobs` such work units SHALL be in flight at once across the process for a given command run.

The work budget SHALL NOT replace the package job limit for how many package-level check or apply jobs may run concurrently. The work budget SHALL NOT force `update` signed commits or preflight to run concurrently.

#### Scenario: Work budget scales with jobs

- **WHEN** the user runs `outdated` with `--jobs 3`
- **THEN** at most six Go planning work units (ceilings discovery, list-versions, or go.mod probes) are in flight at once

#### Scenario: Single job still allows nested overlap

- **WHEN** the user runs `outdated` with `--jobs 1` against a Go package that probes multiple go.mod versions
- **THEN** up to two go.mod probes (or other work-budget units) may proceed concurrently while only one package job is admitted

#### Scenario: Package limit unchanged

- **WHEN** the user runs `outdated` with `--jobs 2` and more than two packages need checks
- **THEN** at most two package-level check jobs run at the same time regardless of the larger work budget

#### Scenario: Commits remain sequential

- **WHEN** multiple packages succeed in update phase 1
- **THEN** signed commits still run one after another regardless of `--jobs` and the work budget
