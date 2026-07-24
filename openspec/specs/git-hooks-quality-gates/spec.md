# git-hooks-quality-gates Specification

## Purpose

Define project quality gates enforced via hk git hooks and check entrypoints: Cabal-managed local tools, strict bootstrap, blocking format/build-test/lint/analysis pipeline, and HIE support for stan and weeder.

## Requirements

### Requirement: Project-local quality tools are Cabal-managed

The project SHALL pin and install the quality tools ormolu, hlint, stan, and weeder via Cabal into a project-local `.tools/bin` directory. Tool versions SHALL be constrained in project Cabal configuration. The ambient system PATH SHALL NOT be relied upon as the source of these tool binaries for hooks.

#### Scenario: Install script populates tool binaries

- **WHEN** a developer runs the documented install-dev-tools script from the repository root with a working Cabal and project GHC
- **THEN** executable binaries for ormolu, hlint, stan, and weeder are present under `.tools/bin`

#### Scenario: Tool versions are pinned in the repository

- **WHEN** a reader inspects the project Cabal configuration committed in the repository
- **THEN** version constraints for ormolu, hlint, stan, and weeder are present so installs are reproducible

### Requirement: Strict missing-tool policy

Hooks and quality check entrypoints SHALL fail if any required tool binary is missing or not executable under `.tools/bin`. They SHALL NOT auto-install tools. Failure output SHALL instruct the user to run the install-dev-tools script.

#### Scenario: Missing tool blocks the check

- **WHEN** a required tool binary is absent from `.tools/bin` and the developer runs the quality check entrypoint or a git hook that needs that tool
- **THEN** the run fails with a non-zero exit status and a message that names the install-dev-tools script

#### Scenario: No silent fallback to global tools

- **WHEN** a tool exists only on the system PATH but not under `.tools/bin`
- **THEN** the quality check entrypoint or hook still fails the strict missing-tool check for that tool

### Requirement: Blocking quality pipeline

The configured git pre-commit hook and the project quality check entrypoint SHALL run the following steps in order, and SHALL fail the overall run if any step fails:

1. ormolu (format verification and, on fix-oriented runs, in-place format)
2. `cabal test all` (compile and tests)
3. hlint
4. stan
5. weeder

All five steps are blocking.

#### Scenario: Successful clean tree

- **WHEN** `.tools/bin` contains all required tools, the tree is ormolu-clean, all tests pass, and hlint, stan, and weeder report no failures
- **THEN** the quality check entrypoint exits successfully

#### Scenario: Test failure blocks the pipeline

- **WHEN** `cabal test all` fails
- **THEN** the overall hook or check fails and subsequent analyzer steps are not required to report success

#### Scenario: Formatter issues are enforced

- **WHEN** staged or selected Haskell sources are not formatted according to ormolu on a check-oriented run
- **THEN** the overall hook or check fails

#### Scenario: Analyzer failure blocks the pipeline

- **WHEN** hlint, stan, or weeder exits with a failure status
- **THEN** the overall hook or check fails

### Requirement: HIE artifacts for static analysis

Project build configuration SHALL enable generation of HIE files (including `-fwrite-ide-info` and a stable HIE output directory) so stan and weeder analyze artifacts produced by the project GHC. Generated HIE output SHALL be gitignored.

#### Scenario: Build emits HIE for analysis

- **WHEN** a developer runs a full project build or test with the project configuration after a clean state
- **THEN** HIE files exist under the configured HIE directory for compiled project modules

#### Scenario: HIE directory is not versioned

- **WHEN** HIE files are generated under the configured directory
- **THEN** that directory is ignored by git

### Requirement: Weeder configuration

The repository SHALL include a weeder configuration that defines roots appropriate to this package (including executable and test entrypoints as needed) so dead-code analysis is meaningful for a library-plus-executable layout. Weeder configuration SHALL NOT list every library module as a blanket `root-modules` entry solely to suppress weeds on an application-internal library surface. Roots SHALL reflect real program entrypoints and any intentionally public exports that are justified in the configuration comments or project docs.

#### Scenario: Weeder runs with project config

- **WHEN** weeder is invoked as part of the quality pipeline with HIE files present
- **THEN** weeder uses the repository weeder configuration file and exits non-zero only when it reports weeds (or a tool error), not because configuration is missing

#### Scenario: Roots are not a full-module blanket

- **WHEN** a reader inspects the committed weeder configuration
- **THEN** `root-modules` does not enumerate essentially the entire library module set without entrypoint-oriented justification

### Requirement: hk-based hook entrypoints

The repository SHALL provide an `hk.pkl` configuration that wires the quality pipeline for at least pre-commit and for hk's check/fix entrypoints. Developers with hk installed SHALL be able to install hooks via `hk install` (or use an existing global hk install that picks up this `hk.pkl`).

#### Scenario: Pre-commit uses project hk config

- **WHEN** hk hooks are active for the repository and the developer creates a commit
- **THEN** hk runs the configured pre-commit steps from the repository `hk.pkl`

#### Scenario: Manual check uses the same gates

- **WHEN** a developer runs `hk check` (or the project's documented check alias) with tools installed
- **THEN** the same blocking quality pipeline requirements apply

### Requirement: Stan configuration is repository-owned

The repository SHALL include a Stan configuration file used by the quality pipeline. The configuration MAY exclude some severities or categories with documented project intent, but the quality pipeline SHALL still invoke stan as a blocking step. Tightening excludes (enabling previously deferred severities) SHALL keep `hk check` / stan green for the committed baseline.

#### Scenario: Stan config present for pipeline

- **WHEN** a developer inspects the repository for static analysis configuration
- **THEN** a Stan configuration file exists and is what the quality pipeline uses for stan

#### Scenario: Enabled checks are passable

- **WHEN** the tree is clean relative to the committed Stan baseline and HIE is fresh
- **THEN** stan exits successfully under the quality pipeline
