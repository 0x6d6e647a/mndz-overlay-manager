## MODIFIED Requirements

### Requirement: Blocking quality pipeline

The configured git pre-commit hook and the project quality check entrypoint SHALL run the following steps in order, and SHALL fail the overall run if any step fails:

1. ormolu (format verification and, on fix-oriented runs, in-place format)
2. non-coverage project build that emits HIE for static analysis (`cabal build all` or equivalent)
3. coverage-enabled tests and coverage report generation (Cabal `--enable-coverage` via the documented coverage entrypoint), which is the blocking test gate
4. hlint
5. stan
6. weeder

All six steps are blocking. The pipeline SHALL NOT rely on a separate uninstrumented `cabal test all` as the sole test gate when the coverage entrypoint is configured. Stan and weeder SHALL continue to use HIE from the non-coverage build path.

#### Scenario: Successful clean tree

- **WHEN** `.tools/bin` contains all required tools, the tree is ormolu-clean, the non-coverage build succeeds, coverage-enabled tests pass, required coverage reports are produced, and hlint, stan, and weeder report no failures
- **THEN** the quality check entrypoint exits successfully

#### Scenario: Test failure blocks the pipeline

- **WHEN** coverage-enabled tests fail
- **THEN** the overall hook or check fails and subsequent analyzer steps are not required to report success

#### Scenario: Coverage report failure blocks the pipeline

- **WHEN** coverage-enabled tests pass but the coverage entrypoint fails to produce required reports
- **THEN** the overall hook or check fails

#### Scenario: Formatter issues are enforced

- **WHEN** staged or selected Haskell sources are not formatted according to ormolu on a check-oriented run
- **THEN** the overall hook or check fails

#### Scenario: Analyzer failure blocks the pipeline

- **WHEN** hlint, stan, or weeder exits with a failure status
- **THEN** the overall hook or check fails

#### Scenario: HIE build remains non-coverage

- **WHEN** the quality pipeline runs stan or weeder after a successful pipeline build step
- **THEN** analysis uses HIE produced by the non-coverage build step, not as a substitute for the coverage-enabled test step

## ADDED Requirements

### Requirement: Coverage entrypoint is part of hk configuration

The repository `hk.pkl` (or equivalent hk configuration) SHALL invoke the documented coverage entrypoint as the blocking test-and-coverage step of the quality pipeline for pre-commit and for `hk check` (or the project’s documented check entrypoint).

#### Scenario: Pre-commit runs coverage

- **WHEN** hk pre-commit hooks are active and a developer creates a commit
- **THEN** hk runs the coverage-enabled test and report step as part of the configured pipeline

#### Scenario: Manual check runs coverage

- **WHEN** a developer runs `hk check` with tools installed
- **THEN** the same coverage-enabled test and report step is required for success
