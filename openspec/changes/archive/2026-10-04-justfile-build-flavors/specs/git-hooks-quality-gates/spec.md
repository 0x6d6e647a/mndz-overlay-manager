## MODIFIED Requirements

### Requirement: Blocking quality pipeline

The configured git pre-commit hook and the project quality check entrypoint SHALL run the following steps in order, and SHALL fail the overall run if any step fails:

1. ormolu (format verification and, on fix-oriented runs, in-place format)
2. non-coverage release-flavor build that emits HIE for static analysis
3. coverage-enabled tests and coverage report generation on the debug coverage flavor (Cabal `--enable-coverage` via the documented coverage entrypoint), which is the blocking test gate
4. hlint
5. stan
6. weeder

All six steps are blocking. The pipeline SHALL NOT rely on a separate uninstrumented `cabal test all` as the sole test gate when the coverage entrypoint is configured. Stan and weeder SHALL use HIE from the non-coverage release-flavor build, not HIE emitted by a coverage build. The optimized coverage flavor SHALL NOT be a step of this pipeline.

#### Scenario: Successful clean tree

- **WHEN** `.tools/bin` contains all required tools, the tree is ormolu-clean, the non-coverage release build succeeds, debug-coverage tests pass, required coverage reports are produced, and hlint, stan, and weeder report no failures
- **THEN** the quality check entrypoint exits successfully

#### Scenario: Test failure blocks the pipeline

- **WHEN** debug-coverage tests fail
- **THEN** the overall hook or check fails and subsequent analyzer steps are not required to report success

#### Scenario: Coverage report failure blocks the pipeline

- **WHEN** debug-coverage tests pass but the coverage entrypoint fails to produce required reports
- **THEN** the overall hook or check fails

#### Scenario: Formatter issues are enforced

- **WHEN** staged or selected Haskell sources are not formatted according to ormolu on a check-oriented run
- **THEN** the overall hook or check fails

#### Scenario: Analyzer failure blocks the pipeline

- **WHEN** hlint, stan, or weeder exits with a failure status
- **THEN** the overall hook or check fails

#### Scenario: HIE build remains non-coverage

- **WHEN** the quality pipeline runs stan or weeder after a successful pipeline build step
- **THEN** analysis uses HIE produced by the non-coverage release-flavor build, not HIE from the debug coverage build or the optimized coverage flavor

### Requirement: HIE artifacts for static analysis

Project build configuration SHALL enable generation of HIE files (including `-fwrite-ide-info`) for the dev flavor and the release flavor. The quality pipeline SHALL collect those files into a stable per-flavor HIE directory, with separate library, executable, and test outputs so the executable and test entry modules do not overwrite each other. Stan and weeder SHALL read only the release flavor's collected HIE directory. Coverage builds SHALL NOT write or replace that directory. Generated HIE output and flavor build directories SHALL be gitignored.

#### Scenario: Build emits HIE for analysis

- **WHEN** the non-coverage release-flavor build used by the quality pipeline completes
- **THEN** HIE files for compiled library, executable, and test modules exist under the release flavor's collected HIE directory

#### Scenario: Coverage does not replace release HIE

- **WHEN** the debug coverage gate build completes after a release-flavor HIE collection
- **THEN** the release flavor's collected HIE files are unchanged

#### Scenario: HIE directory is not versioned

- **WHEN** HIE files are generated under a flavor's collected HIE directory
- **THEN** that directory is ignored by git
