# Spec Delta

## MODIFIED Requirements

### Requirement: Per-command tree snapshot

Before the first run, `smoke`, and `update` when it needs gated runs, SHALL copy the managed Gentoo tree at its resolved commit, without git metadata, into a Docker image tagged `mndz-overlay-manager/smoke-tree:<run-id>`. Every smoke container of that command SHALL mount that image read-only at `/var/db/repos/gentoo`. All runs of one command SHALL therefore see the same tree commit, whatever happens to the managed tree meanwhile. For `update`, that commit SHALL be the one its Portage tools use in that run.

#### Scenario: Sync during a smoke command

- **WHEN** another command syncs the managed tree to a new commit while `smoke` is on its fifth run
- **THEN** the remaining smoke runs still see the commit the snapshot was taken from

#### Scenario: Snapshot is read-only

- **WHEN** a process in a smoke container writes under `/var/db/repos/gentoo`
- **THEN** the write fails

#### Scenario: One snapshot per update

- **WHEN** `update` gates three units
- **THEN** all their runs mount the same `smoke-tree:<run-id>` image

### Requirement: Tree snapshot is removed at exit

`smoke`, and `update` when it took a snapshot, SHALL delete its tree snapshot image when the command ends, whether it succeeded, failed, or was interrupted. At start, before taking a snapshot, the command SHALL delete snapshot images left by earlier commands whose process is no longer running. It SHALL NOT delete the snapshot of a command that is still running.

#### Scenario: Normal exit

- **WHEN** `smoke` finishes
- **THEN** no `mndz-overlay-manager/smoke-tree` image for that run id remains

#### Scenario: Leftover from a crash

- **WHEN** an earlier `smoke` was killed and left its snapshot image, and the operator runs `smoke` again
- **THEN** the leftover image is deleted before the new snapshot is created

#### Scenario: Concurrent smoke command

- **WHEN** a second `smoke` starts while the first is still running
- **THEN** the first command's snapshot image is not deleted

#### Scenario: Update running alongside smoke

- **WHEN** `update` takes a snapshot while a `smoke` command is running
- **THEN** the `smoke` command's snapshot image is not deleted

### Requirement: Sandbox probe before the first emerge

Before the first run, `smoke`, and `update` when it needs gated runs, SHALL verify that network, IPC, and PID namespaces can be created. The check SHALL run in a container from the smoke image, created with the same privileges as a run container. When any cannot be created, `smoke` SHALL exit with status `1` before any emerge, and `update` SHALL act as specified by `update-smoke-gate` for unready gate prerequisites. The error SHALL state that Portage's sandboxes cannot be enforced on this host.

#### Scenario: Namespaces denied

- **WHEN** the host's Docker configuration denies namespace creation even with `SYS_ADMIN`
- **THEN** `smoke` exits with status `1` naming the sandbox requirement
- **AND** no emerge was run

#### Scenario: Namespaces denied during update

- **WHEN** `update` needs gated runs and namespace creation is denied
- **THEN** no unit is published or committed and `update` exits with status `1` naming the sandbox requirement

### Requirement: Overlay is mounted read-only as it is

Each standalone `smoke` container SHALL mount the effective overlay worktree read-only at `/var/db/repos/mndz`. Each gated `update` container SHALL mount the unit's overlay snapshot, as specified by `update-smoke-gate`, read-only at that path. Every smoke container SHALL configure Portage with repository `gentoo` at `/var/db/repos/gentoo` and repository `mndz` with master `gentoo`. No smoke container SHALL receive the GitHub token, GPG agent, or SSH agent.

#### Scenario: Overlay eclass resolves

- **WHEN** a run installs an ebuild that inherits an overlay eclass
- **THEN** the eclass resolves from `/var/db/repos/mndz`

#### Scenario: Overlay cannot be written

- **WHEN** a process in the container writes under `/var/db/repos/mndz`
- **THEN** the write fails and the worktree on the host is unchanged

#### Scenario: Gated run sees the unit snapshot

- **WHEN** `update` gates unit A while unit B has uncommitted changes in the worktree
- **THEN** `/var/db/repos/mndz` in A's container shows B's package as at `HEAD`

### Requirement: The package under test is built from source and fetched fresh

The second emerge step SHALL install exactly the ebuild under test, addressed by its exact version in the `mndz` repository, building it from source. That step SHALL use an empty distfiles directory inside the container, so every distfile of the package under test is obtained during that run. In standalone `smoke` every such distfile SHALL be downloaded. In a gated `update` run, staged assets distfiles SHALL be delivered as specified by `update-smoke-gate`, and every other distfile SHALL be downloaded. A failure in this step SHALL be reported as stage `build`.

#### Scenario: Dead download URL

- **WHEN** a distfile of the package under test is no longer downloadable and an earlier smoke command had fetched it
- **THEN** the run fails in the package step

#### Scenario: Exact version

- **WHEN** the run is for `dev-util/beads-1.0.4` and `1.3.4` is also on disk
- **THEN** the installed version is `1.0.4`

#### Scenario: Standalone smoke has no fetch shim

- **WHEN** the operator runs `smoke hk`
- **THEN** every assets-repository distfile of the package under test is downloaded from GitHub
