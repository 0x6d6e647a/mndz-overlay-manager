## ADDED Requirements

### Requirement: Project Cabal builds use host-CPU parallelism

The repository Cabal project configuration SHALL set package-level job concurrency to the host processor count (Cabal `$ncpus` or equivalent) and SHALL enable Cabal’s GHC jobserver semaphore so components can compile modules in parallel without oversubscribing the host. Project-aware quality-gate builds (`cabal build all` or equivalent non-coverage HIE build, and coverage-enabled `cabal test` via the coverage entrypoint) SHALL inherit these settings without requiring per-invocation flags in hk configuration.

#### Scenario: Project file enables jobs and semaphore

- **WHEN** a reader inspects the committed Cabal project configuration
- **THEN** it configures jobs equal to host CPU count (via `$ncpus` or equivalent) and enables the semaphore option

#### Scenario: Bare quality-gate build inherits parallelism

- **WHEN** the quality pipeline runs a non-coverage `cabal build all` (or equivalent) with the project configuration
- **THEN** that build uses the project jobs and semaphore settings without hk needing to pass `-j` or `--semaphore` on the command line

### Requirement: install-dev-tools enables parallelism when ignoring the project

The install-dev-tools script SHALL pass package-level parallel jobs and GHC jobserver semaphore flags (for example `-j --semaphore`) to its `cabal install` invocation when that invocation uses `--ignore-project` (or otherwise does not load the repository project file). Those flags SHALL allow the tool install to use host-CPU parallelism equivalent in intent to the project Cabal configuration.

#### Scenario: Tool install passes parallel flags

- **WHEN** a developer runs the documented install-dev-tools script
- **THEN** the `cabal install` command includes flags that enable multi-job builds and the Cabal semaphore (or an equivalent combination that achieves host-CPU parallel package and module compilation)
