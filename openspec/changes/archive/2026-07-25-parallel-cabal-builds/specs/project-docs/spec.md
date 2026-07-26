## ADDED Requirements

### Requirement: Document multi-core Cabal build policy

`CONTRIBUTING.md` SHALL document that project Cabal builds use host-CPU package jobs (`jobs: $ncpus` or equivalent) and the GHC jobserver semaphore by default, that contributors may override concurrency with Cabal CLI flags (for example `-jN`) or a gitignored `cabal.project.local`, and that `./scripts/install-dev-tools` passes equivalent parallel flags because it uses `--ignore-project`.

#### Scenario: CONTRIBUTING describes parallelism defaults

- **WHEN** a contributor reads quality-workflow or bootstrap documentation
- **THEN** `CONTRIBUTING.md` states that Cabal builds default to host-CPU parallelism with the semaphore enabled

#### Scenario: CONTRIBUTING describes overrides and install-dev-tools

- **WHEN** a contributor needs to cap jobs on a memory-constrained machine or understand tool install behavior
- **THEN** `CONTRIBUTING.md` documents override mechanisms and that install-dev-tools enables parallelism despite ignoring the project file
