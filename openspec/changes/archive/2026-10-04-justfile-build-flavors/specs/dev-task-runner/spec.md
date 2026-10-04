## Purpose

Just recipes are the contributor and agent entry point for building, testing, running the manager, coverage, and the quality gate, with separate build flavors so those activities do not recompile each other.

## ADDED Requirements

### Requirement: Just is the documented task entry

The repository SHALL provide a justfile at the repository root as the documented entry point for building, testing, running the manager, coverage, and the quality-gate shortcuts. `just` SHALL be a system tool, not a binary installed by the install-dev-tools script. Running `just` with no recipe SHALL list the recipes and SHALL NOT launch the manager.

#### Scenario: Bare just lists recipes

- **WHEN** a contributor runs `just` in the repository root with no recipe name
- **THEN** just lists the documented recipes and does not start the manager

#### Scenario: Just is not a project-local quality tool

- **WHEN** a contributor runs the install-dev-tools script
- **THEN** that script does not install `just` into `.tools/bin`

### Requirement: Run recipe forwards manager arguments

The `run` recipe SHALL invoke the manager and forward every argument after the recipe name, in order, as the manager's own arguments. Global options remain before the work command, matching the manager's parser. A leading `--` that the task runner uses only to separate its own flags SHALL NOT be passed to the manager. The recipe's exit status SHALL be the manager's exit status. The recipe SHALL leave the manager's standard input, output, and error attached to the contributor's terminal.

#### Scenario: Globals stay before the work command

- **WHEN** a contributor runs `just run --jobs 4 outdated --refresh crush`
- **THEN** the manager receives `--jobs`, `4`, `outdated`, `--refresh`, and `crush` in that order

#### Scenario: A separator is not a manager argument

- **WHEN** a contributor runs `just run -- --jobs 4 outdated crush`
- **THEN** the manager receives `--jobs`, `4`, `outdated`, and `crush`, and does not receive a leading `--`

#### Scenario: Interactive token prompt still reaches the terminal

- **WHEN** a contributor runs `just run github-token` on a controlling terminal
- **THEN** the manager's prompts are read from that terminal

### Requirement: Short build recipes are the dev flavor

`build`, `test`, and `run` SHALL use the dev flavor: unoptimized compilation, debug info, and runtime stack provenance. `test` SHALL run the uninstrumented suite. When `test` is given a pattern, it SHALL restrict the suite to that pattern. `build`, `test`, and `run` SHALL NOT accept extra Cabal flags.

`build-release`, `test-release`, and `run-release` SHALL use the release flavor: Cabal's default optimization (level 1), without the dev flavor's debug info or stack-provenance flags. `test-release` SHALL run the uninstrumented suite.

The task runner SHALL NOT define a separate recipe for each manager work command. Work commands are arguments to `run` or `run-release`.

#### Scenario: Short test recipe is unoptimized and uninstrumented

- **WHEN** a contributor runs `just test`
- **THEN** the suite runs from the dev flavor, without coverage instrumentation

#### Scenario: Test pattern filters the suite

- **WHEN** a contributor runs `just test Unit`
- **THEN** only tests matching that pattern run, still on the dev flavor

#### Scenario: Release run is optimized

- **WHEN** a contributor runs `just run-release list`
- **THEN** the manager binary that runs was built with the release flavor, not the dev flavor

#### Scenario: No per-command work recipes

- **WHEN** a contributor lists just recipes
- **THEN** `outdated`, `update`, `gencache`, `eclean`, `list`, and `github-token` are not recipes

### Requirement: Coverage recipes use separate flavors

`coverage` SHALL run the debug coverage flavor: the dev flavor's compile flags plus coverage instrumentation. With no pattern, `coverage` SHALL produce the gate's Overall, Unit, and Integration reports. With a pattern, `coverage` SHALL rerun that pattern on the same debug coverage flavor.

`coverage-release` SHALL run coverage instrumentation on the release flavor and SHALL NOT be part of the quality gate. Neither coverage recipe SHALL replace the other flavor's build products.

#### Scenario: Coverage with no pattern is the gate report

- **WHEN** a contributor runs `just coverage` with no pattern
- **THEN** the debug coverage flavor runs and the Overall, Unit, and Integration reports are produced

#### Scenario: Coverage pattern reruns one test on the debug flavor

- **WHEN** a contributor runs `just coverage Overlay`
- **THEN** only tests matching that pattern run, on the debug coverage flavor

#### Scenario: Optimized coverage is not the gate

- **WHEN** a contributor runs `just coverage-release`
- **THEN** the release coverage flavor runs, and a failure of that recipe is not by itself a quality-gate failure

### Requirement: Flavors do not recompile each other

Dev, release, coverage-dev, and coverage-release SHALL use separate build directories. Building one flavor SHALL NOT discard or invalidate object files of another flavor whose sources and flags are unchanged.

#### Scenario: Dev then release then dev

- **WHEN** a contributor runs a successful `just build`, then `just build-release`, then `just build` again, and no sources changed
- **THEN** the second `just build` does not recompile the dev flavor's unchanged modules

#### Scenario: Gate coverage does not wipe the dev build

- **WHEN** a contributor runs a successful `just build` and then `just coverage`, and no sources changed
- **THEN** the dev flavor's object files are still present and a later `just build` does not recompile unchanged modules

### Requirement: Quality shortcuts

`check` SHALL run the full quality gate and SHALL NOT install missing tools. `format` SHALL run ormolu in place on Haskell sources and SHALL NOT stage files and SHALL NOT run other fixers. `hlint` SHALL run only the hlint step. `stan` and `weeder` SHALL analyze HIE from the non-coverage release build, and SHALL build that release flavor first when its HIE is missing or stale.

`init` SHALL install project-local quality tools and then install the repository git hooks. `init` SHALL NOT build the manager. `check` SHALL NOT depend on `init`.

#### Scenario: Check does not install tools

- **WHEN** a required tool binary is missing from `.tools/bin` and a contributor runs `just check`
- **THEN** the check fails and does not install the tool

#### Scenario: Format is ormolu only and does not stage

- **WHEN** a contributor runs `just format` and ormolu rewrites a tracked Haskell file
- **THEN** that file is formatted in place, the file is not staged by the recipe, and no other fixer runs

#### Scenario: Init installs tools and hooks only

- **WHEN** a contributor runs `just init` from a checkout whose tools and hooks are not yet installed
- **THEN** `.tools/bin` gains the quality-tool binaries and the git hooks are installed, and the manager is not built
