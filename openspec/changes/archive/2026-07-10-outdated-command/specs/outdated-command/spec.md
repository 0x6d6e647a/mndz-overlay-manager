## ADDED Requirements

### Requirement: Outdated subcommand spine

The CLI SHALL provide an `outdated` subcommand that, like `list`, loads configuration, resolves the overlay path (config then optional `--overlay-path`), validates the overlay, and discovers ebuilds before performing update checks. Hard failures on that spine SHALL log an error and exit with status `1`. Empty inventory SHALL be treated as an error with exit status `1`.

#### Scenario: Successful spine with packages

- **WHEN** the user runs `outdated` against a valid overlay containing ebuilds
- **THEN** the program loads config, validates the overlay, discovers ebuilds, and proceeds to per-package checks

#### Scenario: Empty inventory

- **WHEN** the user runs `outdated` against a valid overlay with zero ebuilds
- **THEN** the program logs an error and exits with status `1`

### Requirement: Per-package newest local version

For each `category/package` with one or more ebuilds, the check SHALL use the newest local version by PV ordering as the local side of the comparison and SHALL use that ebuild's file for source inference when needed.

#### Scenario: Multiple ebuild versions

- **WHEN** a package directory contains ebuilds for `9.4.5` and `9.6.1`
- **THEN** the local version used for the update check is `9.6.1`

### Requirement: Outdated stdout format

For each package whose local PV is strictly less than the fetched remote PV, the program SHALL write exactly one line to standard output of the form `category/package vLOCAL -> vREMOTE`, where `vLOCAL` and `vREMOTE` are pretty-rendered ebuild versions (leading `v`, optional `-rN` on local when present). Packages that are up to date SHALL NOT produce a stdout line.

#### Scenario: Package behind upstream

- **WHEN** local newest PV is `2.1.6` and remote is `2.1.10` for `dev-db/dolt`
- **THEN** stdout contains the line `dev-db/dolt v2.1.6 -> v2.1.10`

#### Scenario: Package up to date is silent on stdout

- **WHEN** local and remote PV are equal for a package
- **THEN** the program writes no stdout line for that package

### Requirement: Soft warnings on stderr

The program SHALL log a warning (default log level includes warnings) for each package that is unconfigured (no source), fails fetch or remote version parse, or is ahead of upstream (local PV greater than remote). Soft outcomes SHALL NOT cause a non-zero exit by themselves.

#### Scenario: Unconfigured package

- **WHEN** a package has neither a hardcoded nor an inferred update source
- **THEN** the program logs a warning naming that `category/package` and continues

#### Scenario: Ahead of upstream

- **WHEN** local PV is greater than remote PV for a package
- **THEN** the program logs a warning for that package and does not write an outdated stdout line for it

#### Scenario: Fetch failure

- **WHEN** upstream fetch fails for a package
- **THEN** the program logs a warning describing the failure and continues checking remaining packages

### Requirement: Exit zero on successful check

When the spine succeeds and the per-package check loop completes, the program SHALL exit with status `0` even if some packages are outdated, unconfigured, ahead, or soft-failed.

#### Scenario: Outdated packages still exit zero

- **WHEN** at least one package is outdated and no hard spine error occurred
- **THEN** the program exits with status `0`

#### Scenario: All current exits zero with empty stdout

- **WHEN** every configured package is up to date and there are no soft-failure warnings required beyond silence for ok packages
- **THEN** the program exits with status `0` and stdout has no outdated lines

### Requirement: Outdated has no subcommand-specific options

The `outdated` subcommand SHALL accept no arguments or subcommand-local flags in this change. Global options such as `--config`, `--overlay-path`, and log verbosity still apply.

#### Scenario: Invoked with global options only

- **WHEN** the user runs `outdated` with only top-level flags such as `--config` or `--overlay-path`
- **THEN** the program treats `outdated` as a zero-argument subcommand and proceeds with the check pipeline
