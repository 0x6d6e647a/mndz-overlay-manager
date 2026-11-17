# Spec Delta

## MODIFIED Requirements

### Requirement: Every consumer uses the managed tree

Lane ceiling discovery, ensure atom choice, materialize image builds, materialize sessions, Portage tool runs, smoke run planning, smoke image builds, and smoke containers SHALL read the Gentoo repository only from the managed tree, or from a snapshot the program took of it. The program SHALL NOT run `portageq` to find a Gentoo repository, SHALL NOT read the host `/var/db/repos/gentoo` or host `repos.conf` for that purpose, and SHALL NOT offer a config key that points at another tree.

#### Scenario: Host tree is not consulted

- **WHEN** the host has a Gentoo tree at `/var/db/repos/gentoo` with different ebuilds from the managed tree
- **THEN** lane ceilings and ensure atom choice reflect the managed tree only

#### Scenario: Host without Portage plans lanes

- **WHEN** `portageq` is not installed on the host and the managed tree is current
- **THEN** `outdated` plans DepsAndAssets lanes without error

#### Scenario: Smoke container sees the managed tree's commit

- **WHEN** `smoke` resolved the managed tree at commit `C`
- **THEN** every container of that command resolves dependencies against commit `C`

### Requirement: Commands that sync

`outdated`, `update`, `gencache`, and `smoke` SHALL ensure the managed tree exists and SHALL sync it when due, before any work that reads it. `--refresh` on `outdated` or `update` SHALL force a sync regardless of age. `smoke` has no `--refresh` and SHALL sync only when due. `list`, `eclean`, and help SHALL NOT sync or require the tree.

#### Scenario: Refresh forces a sync

- **WHEN** the operator runs `outdated --refresh` with a tree synced ten minutes ago
- **THEN** the program syncs the tree before planning

#### Scenario: list does not sync

- **WHEN** the operator runs `list`
- **THEN** the program does not run `git` or `gpg` for the tree

#### Scenario: Smoke syncs a stale tree

- **WHEN** the last successful sync check was seven hours ago with the default max age and the operator runs `smoke`
- **THEN** the program syncs the tree before planning runs

#### Scenario: Smoke leaves a fresh tree alone

- **WHEN** the last successful sync check was one hour ago and the operator runs `smoke`
- **THEN** the program does not contact the mirror or the binhost for the tree

### Requirement: Sync waits for runs using the tree

A sync SHALL hold an exclusive lock on the managed tree. A command that reads the tree SHALL hold a shared lock on it from its first read until it exits, except `smoke`, which SHALL release its shared lock once its tree snapshot exists and SHALL NOT read the managed tree after that. A due sync SHALL wait until it can take the exclusive lock, and readers SHALL wait for a running sync to finish.

#### Scenario: Sync waits for a running update

- **WHEN** an `update` holds the tree and a second command finds the tree due for sync
- **THEN** the second command waits until the `update` releases the tree, then syncs

#### Scenario: Readers never see a partial checkout

- **WHEN** a sync is checking out a new commit
- **THEN** no other manager command reads the tree until the checkout completes

#### Scenario: Long smoke command does not block a sync

- **WHEN** `smoke` has taken its tree snapshot and is running its emerges, and `outdated` finds the tree due for sync
- **THEN** `outdated` syncs without waiting for `smoke` to finish
