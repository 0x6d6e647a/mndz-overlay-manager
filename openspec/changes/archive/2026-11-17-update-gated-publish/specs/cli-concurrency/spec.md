# Spec Delta

## MODIFIED Requirements

### Requirement: Job pool applies to package checks and apply phase one

The jobs limit SHALL bound concurrent per-package work for `outdated` checks and for `update` phase-1 apply of **admitted** packages. The limit SHALL NOT require every selected package to be admitted at the start of mutate; overlay wait-edge consumers withheld as specified by `overlay-apply-waves` SHALL NOT count as in-flight phase-1 jobs while waiting. Packages waiting on materialize image ensure as specified by `ensure-materialize-image` SHALL NOT count as in-flight phase-1 jobs while waiting. Image ensure itself SHALL NOT occupy a package job slot. Units waiting for the smoke lane, waiting at their gate for an overlay dependency, or running their gated smoke runs, as specified by `update-smoke-gate`, SHALL NOT count as in-flight phase-1 jobs. The limit SHALL NOT force preflight steps, image ensure, gated runs, or signed commits to run concurrently as package jobs; overlay commits remain sequential.

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

#### Scenario: Gate does not take a job slot

- **WHEN** `--jobs 1`, unit A is in its gated run, and unit B is admitted
- **THEN** B may run phase-1 while A's gated run is active

#### Scenario: Dependency wait does not take a job slot

- **WHEN** `--jobs 1` and `codex-acp` waits at its gate for `codex`
- **THEN** `codex` is not blocked from a job slot by `codex-acp`'s wait

### Requirement: Jobs sets build parallelism for smoke

For `smoke`, and for the gated runs of `update`, the resolved `--jobs` value `N` SHALL set the build parallelism inside each smoke container as `MAKEOPTS="-j<N> -l<N+1>"`, and each emerge SHALL run one package job at a time. `--jobs` SHALL NOT cause more than one smoke run or more than one smoke container to be active at once within one command.

#### Scenario: Explicit jobs

- **WHEN** the operator runs `--jobs 8 smoke crush`
- **THEN** the emerges in the container run with `MAKEOPTS="-j8 -l9"`
- **AND** each emerge runs with one package job

#### Scenario: Default jobs

- **WHEN** the operator runs `smoke` without `--jobs` on a host with 16 processors
- **THEN** the emerges run with `MAKEOPTS="-j16 -l17"`

#### Scenario: Runs stay sequential

- **WHEN** the operator runs `--jobs 4 smoke` with many packages selected
- **THEN** at most one smoke container exists at any time

#### Scenario: Update gates stay sequential

- **WHEN** the operator runs `--jobs 4 update` and several units reach their gates
- **THEN** at most one smoke container of that `update` exists at any time
