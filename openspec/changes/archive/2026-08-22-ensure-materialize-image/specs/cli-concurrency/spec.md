## MODIFIED Requirements

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
