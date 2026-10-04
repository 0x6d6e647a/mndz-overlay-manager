## MODIFIED Requirements

### Requirement: Contributor documentation of test layout

When the test suite is organized into multiple modules under a standard harness (rather than a single monolithic test Main with only hand-rolled asserts), `CONTRIBUTING.md` SHALL document how to run the full uninstrumented test suite and the quality gate (`just test` and `just check`) and how to select a subset of tests with the documented test recipe's pattern.

#### Scenario: CONTRIBUTING documents test run

- **WHEN** a contributor reads `CONTRIBUTING.md` for quality workflows
- **THEN** the file describes `just test` and `just check` as the uninstrumented suite and the quality gate
- **AND** the file shows how to pass a test pattern to `just test`

### Requirement: Document multi-core Cabal build policy

`CONTRIBUTING.md` SHALL document that project Cabal builds use host-CPU package jobs (`jobs: $ncpus` or equivalent) and the GHC jobserver semaphore by default, that a persistent job cap belongs in gitignored `cabal.project.local` so quality-gate builds see it, that the documented just build recipes do not accept extra Cabal flags, and that `./scripts/install-dev-tools` passes equivalent parallel flags because it uses `--ignore-project`.

#### Scenario: CONTRIBUTING describes parallelism defaults

- **WHEN** a contributor reads quality-workflow or bootstrap documentation
- **THEN** `CONTRIBUTING.md` states that Cabal builds default to host-CPU parallelism with the semaphore enabled

#### Scenario: CONTRIBUTING describes overrides and install-dev-tools

- **WHEN** a contributor needs to cap jobs on a memory-constrained machine or understand tool install behavior
- **THEN** `CONTRIBUTING.md` documents `cabal.project.local` as the persistent override, states that just build recipes do not take Cabal flags, and states that install-dev-tools enables parallelism despite ignoring the project file
