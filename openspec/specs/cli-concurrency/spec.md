# cli-concurrency Specification

## Purpose

Bounded package-level job pool (`--jobs`) shared by concurrent check and apply paths, plus nested Go planning work budget and runtime requirements so concurrency is real under blocking IO.

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

The jobs limit SHALL bound concurrent per-package work for `outdated` checks and for `update` phase-1 apply of **admitted** packages. The limit SHALL NOT require every selected package to be admitted at the start of mutate; overlay wait-edge consumers withheld as specified by `overlay-apply-waves` SHALL NOT count as in-flight phase-1 jobs while waiting. Packages waiting on materialize image ensure as specified by `ensure-materialize-image` SHALL NOT count as in-flight phase-1 jobs while waiting. Image ensure itself SHALL NOT occupy a package job slot. The limit SHALL NOT force preflight steps, image ensure, or signed commits to run concurrently as package jobs; overlay commits remain sequential.

#### Scenario: Commits remain sequential

- **WHEN** multiple packages succeed in update phase 1
- **THEN** signed commits still run one after another regardless of `--jobs`

#### Scenario: Outdated checks are concurrent under the limit

- **WHEN** the user runs `outdated` with multiple packages and `--jobs 4`
- **THEN** package update checks may proceed concurrently with at most four in flight

#### Scenario: Withheld consumer does not take a job slot

- **WHEN** `--jobs 1`, bun-bin needs work, and ralph-tui is withheld on bun-bin
- **THEN** bun-bin may run phase-1 while ralph-tui is waiting
- **AND** ralph-tui is not occupying the single job slot solely by waiting

#### Scenario: Ensure does not take a job slot

- **WHEN** `--jobs 1`, bun-bin needs work, and a full-path package waits on image ensure
- **THEN** bun-bin may run phase-1 while ensure runs
- **AND** neither ensure nor the waiting full-path package occupies the single job slot solely by waiting

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
