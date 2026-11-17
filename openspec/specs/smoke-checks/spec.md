# smoke-checks Specification

## Purpose

Define the per-package checks `smoke` runs after an install: which packages must have them, the minimum every package gets, how a check executes, and how its result is decided.

## Requirements

### Requirement: Every policy package has a smoke definition

The program SHALL carry a smoke definition for every package that has a hardcoded update policy, including `Unsupported` packages. A definition SHALL contain at least one check.

#### Scenario: Policy package without a program

- **WHEN** the operator runs `smoke craft-fonts`
- **THEN** the run performs at least one check (for example that the font files are installed)

### Requirement: A selected package without a definition hard-fails

When any selected package has no smoke definition, `smoke` SHALL exit with status `1` before tree, image, or container work, naming every such package.

#### Scenario: Unconfigured overlay package

- **WHEN** the overlay contains `dev-util/newpkg`, which has no update policy and no smoke definition, and the operator runs `smoke`
- **THEN** the program exits with status `1` naming `dev-util/newpkg`
- **AND** no container is created

#### Scenario: Excluding it lets the rest run

- **WHEN** the operator runs `smoke --exclude dev-util/newpkg`
- **THEN** the remaining packages are tested

### Requirement: Floor check

Every definition SHALL include a check that runs an installed program of the package with its version or help option and passes only when the program runs and produces the expected output. For a package that installs no program, the floor check SHALL instead assert that the package's installed files exist.

#### Scenario: Version floor

- **WHEN** `dev-util/crush-0.101.0` is installed and its floor check runs `crush --version`
- **THEN** the check passes when the command exits `0` and its output contains `0.101.0`

#### Scenario: Program cannot start

- **WHEN** the installed program fails to start because a shared library is missing
- **THEN** the floor check fails

### Requirement: Version expectations use the installed version

A check that asserts a version SHALL compare against the PV of the ebuild under test, not a fixed string, so the same definition applies to every version on disk.

#### Scenario: Two versions, one definition

- **WHEN** `dev-util/beads` versions `1.0.4` and `1.3.4` are tested
- **THEN** the version check expects `1.0.4` in the first run and `1.3.4` in the second

### Requirement: Definitions carry the smoke their package's spec describes

When a package's capability spec states smoke commands and their expected results, the package's definition SHALL include checks that run those commands and assert those results, using the installed version where the spec names a seed version.

#### Scenario: Accepted non-zero exit

- **WHEN** `qlot --version` prints a line containing the installed version and exits with status `255`
- **THEN** the qlot version check passes

#### Scenario: Functional check

- **WHEN** `dev-util/cargo-outdated` is tested
- **THEN** a check runs `cargo outdated` in a throwaway crate that depends on `libc = "0.1"` and passes only when the report lists `libc`

#### Scenario: Start without arguments

- **WHEN** `dev-util/autolith` is tested
- **THEN** a check starts `autolith` with no arguments and empty standard input, and fails when the output reports a missing helper under `/var/tmp/portage`

### Requirement: Checks are named and independent

Each check SHALL have a name unique within its definition and SHALL consist of one or more commands run in order, each with an expectation on its exit status and output. When a command's expectation is not met, the check SHALL fail and its remaining commands SHALL NOT run. Later checks of the same run SHALL still run.

#### Scenario: Second check runs after the first fails

- **WHEN** a definition has checks `version` and `help` and `version` fails
- **THEN** `help` still runs
- **AND** the run's result names only `version` as failed when `help` passes

#### Scenario: Setup command fails

- **WHEN** a check's first command creates a throwaway project and exits non-zero
- **THEN** the check fails and its later commands do not run

### Requirement: Checks run as a non-root user

Check commands SHALL run in the container as a non-root user that has a user database entry and a writable home directory. Check commands SHALL NOT hold `SYS_ADMIN` or run as root. Check commands SHALL run with the environment a login shell of that user gets from `/etc/profile`.

#### Scenario: Program writes its config

- **WHEN** a checked program creates a file under its home directory
- **THEN** the write succeeds and the file is owned by the non-root user

#### Scenario: Variable from env.d

- **WHEN** the package under test sets a variable through `/etc/env.d` (for example `SBCL_HOME`)
- **THEN** check commands see that variable

### Requirement: Check groups per definition

A definition MAY name groups the check user joins for that package's runs. `smoke` SHALL add the check user to exactly those groups, as root, after the package and any extra atoms are installed and before the first check. The membership SHALL exist only in that run's container. A failure to join SHALL fail the run at stage `check groups` and SHALL run no check.

#### Scenario: Configuration readable by a package group

- **WHEN** the `witen-warden-bin` definition names group `witen-warden` and the installed configuration is readable by root and that group only
- **THEN** `warden validate` run as the check user can read the configuration
- **AND** no other package's run adds the check user to `witen-warden`

#### Scenario: Group does not exist

- **WHEN** a definition names a group the installed packages did not create
- **THEN** the run fails at stage `check groups` with its log and no check runs

### Requirement: Check commands time out

Each check command SHALL be stopped when it runs longer than its limit, which is 60 seconds unless the check sets another. A stopped command SHALL fail its check with a reason stating the limit.

#### Scenario: Program waits for input

- **WHEN** a check command blocks reading standard input for longer than 60 seconds
- **THEN** the command is stopped and the check fails stating the 60 second limit
- **AND** the next check runs

### Requirement: Checks declare network use

A check SHALL run without network unless it declares that it needs it (see `smoke-environment`). A check that needs an external service SHALL declare network.

#### Scenario: Registry lookup

- **WHEN** the `cargo outdated` functional check queries the crates.io index
- **THEN** that check declares network and no other check of the definition gains network access because of it

### Requirement: Checks leave no state outside the container

Check commands SHALL create their working files only inside the container. A check SHALL NOT read or modify the operator's home directory, the overlay, or any host path.

#### Scenario: Throwaway project

- **WHEN** a check creates a project directory to exercise a tool
- **THEN** that directory exists only inside the run's container and is gone when the container is removed

### Requirement: Extra atoms, keywords, and USE per definition

A definition MAY name Gentoo atoms to install after the package under test for use by its checks, MAY name Gentoo atoms whose testing keywords are accepted for its runs, and MAY name `package.use` lines (an atom and its flags) for its runs. `smoke` SHALL install, accept, and set exactly those. A failure to install an extra atom SHALL fail the run at stage `check`, naming the atom.

#### Scenario: Helper tool for a check

- **WHEN** a definition names `dev-vcs/git` as an extra atom
- **THEN** `git` is installed after the package under test and before the first check

#### Scenario: Dependency needs a USE flag the profile lacks

- **WHEN** a craft app's default `USE=X` requires `x11-libs/libxkbcommon[X]` and its definition names `x11-libs/libxkbcommon X`
- **THEN** the run's container has that line in `/etc/portage/package.use` and the dependencies step resolves

### Requirement: A run passes only when everything passes

A run SHALL pass only when the dependencies step and the package step succeed and every check passes. Checks SHALL NOT run when either emerge step failed.

#### Scenario: Build fails

- **WHEN** the package step fails
- **THEN** no check command is run and the result is `fail: build`

#### Scenario: One check fails

- **WHEN** both emerge steps succeed and one of three checks fails
- **THEN** the run's result is `fail: check` naming that check
