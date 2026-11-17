# smoke-environment Specification

## Purpose

Define the container each `smoke` run installs into: the tree snapshot and overlay it sees, the privileges it holds, how Portage is configured, and how the package under test and its dependencies are installed.

## Requirements

### Requirement: Per-command tree snapshot

Before the first run, `smoke` SHALL copy the managed Gentoo tree at its resolved commit, without git metadata, into a Docker image tagged `mndz-overlay-manager/smoke-tree:<run-id>`. Every container of that command SHALL mount that image read-only at `/var/db/repos/gentoo`. All runs of one command SHALL therefore see the same tree commit, whatever happens to the managed tree meanwhile.

#### Scenario: Sync during a smoke command

- **WHEN** another command syncs the managed tree to a new commit while `smoke` is on its fifth run
- **THEN** the remaining smoke runs still see the commit the snapshot was taken from

#### Scenario: Snapshot is read-only

- **WHEN** a process in a smoke container writes under `/var/db/repos/gentoo`
- **THEN** the write fails

### Requirement: Tree snapshot is removed at exit

`smoke` SHALL delete its tree snapshot image when the command ends, whether it succeeded, failed, or was interrupted. At start, `smoke` SHALL delete snapshot images left by earlier commands whose process is no longer running, and SHALL NOT delete the snapshot of a command that is still running.

#### Scenario: Normal exit

- **WHEN** `smoke` finishes
- **THEN** no `mndz-overlay-manager/smoke-tree` image for that run id remains

#### Scenario: Leftover from a crash

- **WHEN** an earlier `smoke` was killed and left its snapshot image, and the operator runs `smoke` again
- **THEN** the leftover image is deleted before the new snapshot is created

#### Scenario: Concurrent smoke command

- **WHEN** a second `smoke` starts while the first is still running
- **THEN** the first command's snapshot image is not deleted

### Requirement: One fresh container per run

Each run SHALL use a new container created from the smoke image and SHALL remove it when the run ends, whatever the outcome. No state inside a container SHALL carry over to another run except the binary-package and dependency-distfiles volumes and the package's compile cache (see `smoke-compile-cache`). Containers SHALL carry the product and run labels used for materialize sessions and a name beginning `mndz-smoke-<run-id>-`.

#### Scenario: Failed run leaves no container

- **WHEN** a run fails in a check
- **THEN** its container no longer exists when the next run starts

#### Scenario: Previous install is not visible

- **WHEN** the run for `dev-util/beads-1.0.4` has finished and the run for `dev-util/beads-1.3.4` starts
- **THEN** no `dev-util/beads` version is installed in the new container before its emerge

#### Scenario: Compile cache carries over

- **WHEN** the run for `dev-util/beads-1.0.4` has finished and the run for `dev-util/beads-1.3.4` starts with the compile cache on
- **THEN** the new container sees the compile cache written by the earlier run

### Requirement: Overlay is mounted read-only as it is

Each container SHALL mount the effective overlay worktree read-only at `/var/db/repos/mndz` and SHALL configure Portage with repository `gentoo` at `/var/db/repos/gentoo` and repository `mndz` with master `gentoo`. The container SHALL NOT receive the GitHub token, GPG agent, or SSH agent.

#### Scenario: Overlay eclass resolves

- **WHEN** a run installs an ebuild that inherits an overlay eclass
- **THEN** the eclass resolves from `/var/db/repos/mndz`

#### Scenario: Overlay cannot be written

- **WHEN** a process in the container writes under `/var/db/repos/mndz`
- **THEN** the write fails and the worktree on the host is unchanged

### Requirement: Containers hold CAP_SYS_ADMIN and nothing more

Smoke containers SHALL be created with the `SYS_ADMIN` capability added to Docker's default set. They SHALL NOT be created privileged, SHALL NOT add any other capability, and SHALL NOT disable or replace the default seccomp profile.

#### Scenario: Create arguments

- **WHEN** `smoke` creates a container
- **THEN** the create request adds `SYS_ADMIN` and contains neither `--privileged` nor a `seccomp` security option

### Requirement: Sandbox probe before the first emerge

Before the first run, `smoke` SHALL verify in a container from the smoke image, created with the same privileges as a run container, that network, IPC, and PID namespaces can be created. When any cannot, the command SHALL exit with status `1` before any emerge, with an error stating that Portage's sandboxes cannot be enforced on this host.

#### Scenario: Namespaces denied

- **WHEN** the host's Docker configuration denies namespace creation even with `SYS_ADMIN`
- **THEN** `smoke` exits with status `1` naming the sandbox requirement
- **AND** no emerge was run

### Requirement: Portage sandboxes are on during smoke emerges

Both emerge steps of a run SHALL execute with `network-sandbox`, `ipc-sandbox`, `pid-sandbox`, `sandbox`, `usersandbox`, and `userpriv` in effect. `smoke` SHALL NOT disable any of them for any package.

#### Scenario: Build phase has no network

- **WHEN** the `src_compile` phase of the package under test tries to open a connection to the internet
- **THEN** the connection fails

### Requirement: Stable system with the overlay accepted

Each container SHALL use the image's stable keyword default and SHALL additionally accept testing keywords for every package from the `mndz` repository. It SHALL accept every license. Testing keywords for other Gentoo packages SHALL be accepted only as specified for the runtime cap, the Python slot, and a package's smoke definition. USE settings beyond the profile's SHALL come only from a package's smoke definition.

#### Scenario: Overlay dependency is installable

- **WHEN** the package under test depends on another overlay package that is `~amd64` only
- **THEN** the dependency resolves without further configuration

#### Scenario: Unlisted testing dependency fails

- **WHEN** the package under test requires a Gentoo package that is `~amd64` only, and nothing accepts it
- **THEN** the run fails in the dependencies step

### Requirement: Runtime is capped at the run's ceiling

For a run with a lane ceiling, the container SHALL mask every version of the runtime package above that ceiling and SHALL accept testing keywords for versions at or below it. For Cargo the cap SHALL apply to both `dev-lang/rust` and `dev-lang/rust-bin`. For Bun the runtime package is overlay `dev-lang/bun-bin`.

#### Scenario: Tilde lane installs the tilde ceiling

- **WHEN** the tilde-lane run of a Go package has ceiling `1.27.4` and `dev-lang/go-1.27.4` is `~amd64`
- **THEN** the run builds the package with `dev-lang/go-1.27.4`

#### Scenario: Plain lane does not see newer testing versions

- **WHEN** the plain-lane run has ceiling `1.26.11` and `dev-lang/go-1.27.4` exists in the tree
- **THEN** no `dev-lang/go` version above `1.26.11` is installed in that container

### Requirement: Python slot of a Uv or Pdm ebuild is accepted

For a run of a Uv or Pdm ebuild, the container SHALL accept testing keywords for `dev-lang/python` in the slot the ebuild names.

#### Scenario: Testing-only slot

- **WHEN** an ebuild names Python slot `3.14` and `dev-lang/python:3.14` is `~amd64` only
- **THEN** the dependencies step can install that slot

### Requirement: Dependencies are installed first

The first emerge step of a run SHALL install the dependencies of the package under test and not the package itself. Gentoo packages MAY be installed from the Gentoo binhost or from the smoke binary-package volume. A failure in this step SHALL be reported as stage `dependencies`, and the package step SHALL NOT run.

#### Scenario: Dependency from the binhost

- **WHEN** a dependency has a binary package on the Gentoo binhost for the snapshot's tree
- **THEN** the dependencies step installs that binary package without compiling it

#### Scenario: Dependency failure is labeled

- **WHEN** a dependency fails to build
- **THEN** the run's result is `fail: dependencies`

### Requirement: Overlay packages are always built from source

Every package from the `mndz` repository, whether it is the package under test or a dependency, SHALL be built from its ebuild in the container. `smoke` SHALL NOT install an overlay package from a binary package and SHALL NOT store one in the binary-package volume.

#### Scenario: Overlay dependency edited in place

- **WHEN** an overlay dependency's ebuild was edited without a version change since the last smoke command
- **THEN** the dependencies step builds it from the edited ebuild

### Requirement: The package under test is built from source and fetched fresh

The second emerge step SHALL install exactly the ebuild under test, addressed by its exact version in the `mndz` repository, building it from source. That step SHALL use an empty distfiles directory inside the container, so every distfile of the package under test is downloaded during that run. A failure in this step SHALL be reported as stage `build`.

#### Scenario: Dead download URL

- **WHEN** a distfile of the package under test is no longer downloadable and an earlier smoke command had fetched it
- **THEN** the run fails in the package step

#### Scenario: Exact version

- **WHEN** the run is for `dev-util/beads-1.0.4` and `1.3.4` is also on disk
- **THEN** the installed version is `1.0.4`

### Requirement: Smoke binary-package and distfiles volumes

Dependency binary packages SHALL be kept in the Docker volume `mndz-smoke-binpkgs` and dependency distfiles in the Docker volume `mndz-smoke-distfiles`. Both SHALL persist across smoke commands. `smoke` SHALL NOT read or write the materialize image's build caches or the manager distfiles directory, and `eclean` SHALL NOT remove these volumes.

#### Scenario: Second command reuses a built dependency

- **WHEN** a Gentoo dependency was compiled during one smoke command and is needed again in the next
- **THEN** the next command installs it from `mndz-smoke-binpkgs`

### Requirement: Network is attached only when needed

A container SHALL be attached to a network during its emerge steps and during the install of extra atoms named by the smoke definition. It SHALL be detached from every network before the first check. For a check that declares it needs the network, the container SHALL be attached for that check only and detached afterwards.

#### Scenario: Offline check

- **WHEN** a check that does not declare network runs a command that tries to reach the internet
- **THEN** the connection fails

#### Scenario: Network check

- **WHEN** a check declares network and the next check does not
- **THEN** the first can reach the internet and the second cannot

### Requirement: Compile cache volume is kept by eclean

`eclean` SHALL NOT remove or prune the `mndz-smoke-compile-cache` volume. Removing the whole volume SHALL be a manual operator action.

#### Scenario: Eclean leaves the volume

- **WHEN** the operator runs `eclean`
- **THEN** `mndz-smoke-compile-cache` and its contents are unchanged
