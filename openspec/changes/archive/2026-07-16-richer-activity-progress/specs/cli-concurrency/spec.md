## ADDED Requirements

### Requirement: Work budget for nested Go planning work

In addition to the package job limit, the program SHALL maintain a separate process-wide work budget for nested Go planning resource units with capacity equal to twice the resolved package jobs limit (`2 * jobs`, treating non-positive jobs as 1 before doubling). Package admission and the work budget SHALL use distinct concurrency limiters so nested work cannot deadlock against package slots.

The work budget SHALL gate at least: Go ceiling discovery (portageq and associated gentoo go ebuild scan for that discovery), listing upstream versions for a Go package plan, and each go.mod fetch performed for version candidates. At most `2 * jobs` such work units SHALL be in flight at once across the process for a given command run.

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

### Requirement: Threaded RTS for concurrent package and nested work

The `mndz-overlay-manager` executable and its test suite SHALL be linked with GHC’s threaded runtime (`-threaded`). Concurrent package jobs and nested Go planning units rely on other green threads continuing while one thread blocks on network or other IO. Without the threaded RTS, blocking HTTP MAY freeze the entire process so that only one package job progresses at a time even when the jobs limit is greater than one.

The executable SHOULD enable multi-capability RTS defaults (for example `-with-rtsopts=-N`) so multiple OS threads are used when available.

#### Scenario: Multiple packages in flight during long network work

- **WHEN** the user runs `outdated` against more packages than one, with `--jobs` greater than 1 (or the default host processor count when that value is greater than 1), and at least one package performs long blocking network work (for example many go.mod probes)
- **THEN** more than one package-level check may be in flight at once, subject to the jobs limit, rather than only a single package progressing until its network work completes
