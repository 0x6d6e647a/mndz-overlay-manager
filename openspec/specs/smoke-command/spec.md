# smoke-command Specification

## Purpose

Install every on-disk ebuild version of the selected overlay packages in a clean container and run each package's checks, so the operator learns whether the overlay installs and works without touching the host system.

## Requirements

### Requirement: Smoke subcommand spine

The CLI SHALL provide a `smoke` subcommand that loads configuration, resolves and validates the overlay, and discovers ebuilds before any smoke work, like `outdated`. Hard failures on that spine SHALL log an error and exit with status `1`. Empty inventory SHALL be an error with exit status `1`.

#### Scenario: Successful spine

- **WHEN** the operator runs `smoke` against a valid overlay containing ebuilds
- **THEN** the program loads config, validates the overlay, discovers ebuilds, and proceeds to selection

#### Scenario: Empty inventory

- **WHEN** the operator runs `smoke` against a valid overlay with zero ebuilds
- **THEN** the program logs an error and exits with status `1`

### Requirement: Smoke package targets

`smoke` SHALL accept zero or more package targets and the subcommand-local flag `--exclude` (see `package-exclude`), and no other subcommand-local flag. Each target SHALL be `category/package` or an unambiguous bare package name, resolved with the rules shared with `outdated`. With zero targets the base SHALL be every discovered package. Unknown and ambiguous tokens SHALL hard-fail with exit status `1` before any smoke work. Version or PV values SHALL NOT be accepted as arguments.

#### Scenario: Zero targets selects the whole inventory

- **WHEN** the operator runs `smoke` with no package arguments
- **THEN** every discovered package is selected

#### Scenario: Bare package name

- **WHEN** the operator runs `smoke crush` and exactly one discovered package is named `crush`
- **THEN** only `dev-util/crush` is selected

#### Scenario: Unknown package hard-fails

- **WHEN** the operator runs `smoke missing/pkg`
- **THEN** the program logs an error and exits with status `1` before any container is created

#### Scenario: Refresh is rejected

- **WHEN** the operator runs `smoke --refresh`
- **THEN** option parsing fails with exit status `1` before configuration is loaded

#### Scenario: Version atom is not a target

- **WHEN** the operator runs `smoke =dev-lang/bun-bin-1.4.4`
- **THEN** the program hard-fails as for an unknown package

### Requirement: Every on-disk version is tested

For each selected package, `smoke` SHALL test every non-live ebuild version present in the overlay worktree, not only the newest. Live ebuilds SHALL NOT be tested. The worktree SHALL be used as it is, including uncommitted changes.

#### Scenario: Two versions on disk

- **WHEN** `dev-util/beads` has ebuilds `1.0.4` and `1.3.4` and the operator runs `smoke beads`
- **THEN** both versions are tested

#### Scenario: Uncommitted edit is tested

- **WHEN** an ebuild has uncommitted edits in the worktree
- **THEN** the run installs the edited ebuild

### Requirement: Ebuild not keyworded for the host is skipped

An ebuild whose `KEYWORDS` contains neither the host architecture token nor its `~` form SHALL NOT be installed. Each such ebuild SHALL produce one `skip` result naming the missing keyword. A skip SHALL NOT make the command fail.

#### Scenario: amd64-only package on arm64

- **WHEN** the host is arm64 and an ebuild has `KEYWORDS="-* ~amd64"`
- **THEN** that ebuild is reported as skipped with a reason naming `arm64`
- **AND** no container is created for it

### Requirement: Ebuilds outside runtime lanes get one run

An ebuild of a `GitMvAndManifest` or `Unsupported` package, and an ebuild of a `DepsAndAssets` Uv or Pdm package, SHALL have exactly one run. That run SHALL carry no lane label.

#### Scenario: Binary package

- **WHEN** `dev-lang/deno-bin` has one ebuild on disk
- **THEN** `smoke deno-bin` performs one run with no lane label

#### Scenario: Uv package

- **WHEN** `dev-util/codex-as-mcp` has one ebuild naming Python slot `3.13`
- **THEN** `smoke codex-as-mcp` performs one run

### Requirement: Runtime ceilings come from local trees only

For `DepsAndAssets` Go, Npm, Bun, Cargo, and Sbcl packages, `smoke` SHALL read the host architecture's plain and tilde runtime ceilings from the same sources `runtime-lanes` names (the managed Gentoo tree, or the overlay for Bun). `smoke` SHALL NOT contact upstream sources or read the check cache to decide its runs.

#### Scenario: No upstream requests while planning

- **WHEN** the operator runs `smoke crush`
- **THEN** no request is made to GitHub, a package registry, or a module proxy to decide which runs exist

### Requirement: Lanes served are derived from on-disk ebuilds

For each lane of the host architecture that has a ceiling, the lane SHALL be served by the newest on-disk non-live version of the package whose own runtime floor is at or below that ceiling. The runtime floor SHALL be read from the ebuild text. An ebuild that states no floor SHALL qualify under every ceiling.

#### Scenario: Newest version serves both lanes

- **WHEN** `dev-util/beads` has `1.0.4` (Go floor `1.26.2`) and `1.3.4` (Go floor `1.26.5`), the plain Go ceiling is `1.26.11`, and the tilde ceiling is `1.27.4`
- **THEN** `1.3.4` serves the plain lane and the tilde lane
- **AND** `1.0.4` serves no lane

#### Scenario: Split lanes

- **WHEN** the newest version's floor is above the plain ceiling and at or below the tilde ceiling, and an older version's floor is at or below the plain ceiling
- **THEN** the older version serves the plain lane and the newest version serves the tilde lane

### Requirement: One run per distinct ceiling served

A lane-gated ebuild SHALL have one run for each distinct ceiling among the lanes it serves, with the runtime capped at that ceiling as specified by `smoke-environment`. When the plain and tilde ceilings are equal, the two runs SHALL collapse to one. Each run SHALL carry the lane label form used by `runtime-lanes`.

#### Scenario: Two runs for two ceilings

- **WHEN** `dev-util/beads-1.3.4` serves the plain lane (ceiling `1.26.11`) and the tilde lane (ceiling `1.27.4`) on amd64
- **THEN** it has a run labeled `(dev-lang/go amd64)` and a run labeled `(dev-lang/go ~amd64)`

#### Scenario: Equal ceilings collapse

- **WHEN** an ebuild serves both lanes and both ceilings are `1.27.4`
- **THEN** it has exactly one run

#### Scenario: Runtime with only a tilde ceiling

- **WHEN** every `dev-lang/bun-bin` ebuild is keyworded `~amd64` only and a Bun package's newest ebuild serves the tilde lane
- **THEN** that ebuild has one run labeled `(dev-lang/bun-bin ~amd64)`

### Requirement: Ebuild serving no lane gets one run

A lane-gated ebuild that serves no lane SHALL have exactly one run. The runtime SHALL be capped at the plain ceiling when the ebuild's floor is at or below it, otherwise at the tilde ceiling. When the floor is above every ceiling for the host architecture, or the runtime has no ceiling there, the ebuild SHALL be reported as failed without creating a container, naming the floor and the ceilings.

#### Scenario: Retained older version

- **WHEN** `dev-util/beads-1.0.4` serves no lane and its floor `1.26.2` is at or below the plain ceiling
- **THEN** it has one run labeled `(dev-lang/go amd64)`

#### Scenario: Floor above every ceiling

- **WHEN** an ebuild's Go floor is `1.28.0` and the tilde ceiling is `1.27.4`
- **THEN** that ebuild is reported as failed with a reason naming `1.28.0` and `1.27.4`
- **AND** no container is created for it

### Requirement: Runs are sequential in a stable order

`smoke` SHALL perform one run at a time. Runs SHALL be ordered by package key, then by ascending version, then plain lane before tilde lane. `--jobs` SHALL NOT make runs concurrent (see `cli-concurrency`).

#### Scenario: Jobs does not parallelize runs

- **WHEN** the operator runs `--jobs 8 smoke`
- **THEN** at most one smoke container exists at any time

### Requirement: A failed run does not stop the command

When a run fails, `smoke` SHALL record the failure and continue with the next run. Only failures before the first run (spine, selection, preflight, tree, image, snapshot, sandbox probe) SHALL stop the command.

#### Scenario: Later packages still run

- **WHEN** the run for the first selected package fails to build
- **THEN** the runs for the remaining packages are still performed

### Requirement: One result line per run on stdout

When a run finishes, or an ebuild is skipped or failed without a container, `smoke` SHALL write exactly one line to standard output: the ebuild atom `category/package-PVR`, the lane label in parentheses when the run has one, a colon, and the outcome. The outcome SHALL be `pass`, `skip: <reason>`, or `fail: <stage>`, where the stage is `plan`, `dependencies`, `build`, or `check` followed by the names of the failed checks. Lines SHALL appear in run order.

#### Scenario: Pass line with a lane

- **WHEN** the tilde-lane run of `dev-util/beads-1.3.4` passes on amd64
- **THEN** stdout contains `dev-util/beads-1.3.4 (dev-lang/go ~amd64): pass`

#### Scenario: Failed checks are named

- **WHEN** the run of `dev-lisp/qlot-1.8.4` installs and its check named `version` fails
- **THEN** stdout contains `dev-lisp/qlot-1.8.4: fail: check version`

#### Scenario: Build failure

- **WHEN** the package step of a run fails
- **THEN** that run's line ends with `fail: build`

### Requirement: Summary and exit status

After the last run, `smoke` SHALL log a summary with the counts of passed, failed, and skipped results and the log directory. The exit status SHALL be `0` when no result is a failure and `1` otherwise. Skips SHALL NOT change the exit status.

#### Scenario: All pass

- **WHEN** every run passes
- **THEN** the summary reports zero failures and the exit status is `0`

#### Scenario: One failure

- **WHEN** one of ten runs fails
- **THEN** the summary reports one failure and nine passes and the exit status is `1`

#### Scenario: Only skips

- **WHEN** every selected ebuild is skipped for its keywords
- **THEN** the exit status is `0`

### Requirement: Uncommitted packages are named

The summary SHALL name each tested package whose package directory in the overlay had uncommitted changes (modified, staged, or untracked files) when the command started.

#### Scenario: Edited ebuild

- **WHEN** `dev-util/hk` has a modified ebuild in the worktree and `smoke hk` finishes
- **THEN** the summary states that `dev-util/hk` was tested with uncommitted changes

### Requirement: Run logs are kept under the manager cache

`smoke` SHALL write the full output of each emerge step and of every check command to files under `<cache>/mndz/overlay-manager/smoke/logs/<run-id>/`, where `<cache>` is `XDG_CACHE_HOME` when set and non-empty and `$HOME/.cache` otherwise. For every failed run, the program SHALL log the path of that run's log files. Logs SHALL be written for passing runs as well.

#### Scenario: Failure names its log

- **WHEN** a run fails in the package step
- **THEN** the error logged for that run names a file under `smoke/logs/<run-id>/` that contains the Portage output

### Requirement: Old run logs are pruned

At the start of a `smoke` command, the program SHALL keep the log directories of the ten most recent earlier smoke commands and SHALL delete older ones. `eclean` SHALL NOT delete smoke logs.

#### Scenario: Eleventh run prunes the oldest

- **WHEN** ten earlier smoke log directories exist and the operator runs `smoke` twice more
- **THEN** the oldest earlier directory no longer exists and the ten most recent earlier ones do

### Requirement: Smoke host preflight

Before any tree, image, or container work, `smoke` SHALL verify that `git`, `gpg`, and `docker` are on `PATH`, that the overlay path is a git work tree, that the Docker engine is version 28.0 or newer, and that the engine uses the containerd image store. A failed check SHALL exit with status `1` and name what is missing.

#### Scenario: Classic storage driver

- **WHEN** the Docker engine does not use the containerd image store
- **THEN** `smoke` exits with status `1` naming the containerd image store requirement
- **AND** no image is built and no container is created

#### Scenario: Old engine

- **WHEN** the Docker engine reports version `27.5.1`
- **THEN** `smoke` exits with status `1` naming the minimum version `28.0`

### Requirement: Smoke does not change the overlay or publish anything

`smoke` SHALL NOT write to the overlay worktree, including ebuilds, `Manifest` files, and `metadata/md5-cache`. It SHALL NOT create commits, push, or publish assets, and SHALL NOT require or read the GitHub token, the operator's GPG keys, or the SSH agent.

#### Scenario: Worktree unchanged

- **WHEN** `smoke` finishes, with any mix of passes and failures
- **THEN** `git status` in the overlay shows the same state as before the command

#### Scenario: No token needed

- **WHEN** no GitHub token is configured
- **THEN** `smoke` runs without a token error
