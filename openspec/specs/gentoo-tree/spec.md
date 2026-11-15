# gentoo-tree Specification

## Purpose

Own one verified Gentoo ebuild repository tree under the manager cache, kept current from the Gentoo git mirror and aligned with the Gentoo binhost, so that every consumer in the program reads the same tree.

## Requirements

### Requirement: Managed tree location under XDG cache

The program SHALL keep the Gentoo tree at `${XDG_CACHE_HOME}/mndz/overlay-manager/gentoo` when `XDG_CACHE_HOME` is set and non-empty, and at `${HOME}/.cache/mndz/overlay-manager/gentoo` otherwise. Files in the tree SHALL be owned by the operator. `eclean` SHALL NOT delete it.

#### Scenario: Default tree path

- **WHEN** `XDG_CACHE_HOME` is unset, `HOME` is `/home/op`, and a work command syncs the tree
- **THEN** the tree is at `/home/op/.cache/mndz/overlay-manager/gentoo`

#### Scenario: eclean leaves the tree

- **WHEN** the operator runs `eclean`
- **THEN** the managed tree is unchanged

### Requirement: Every consumer uses the managed tree

Lane ceiling discovery, ensure atom choice, materialize image builds, materialize sessions, and Portage tool runs SHALL read the Gentoo repository only from the managed tree. The program SHALL NOT run `portageq` to find a Gentoo repository, SHALL NOT read the host `/var/db/repos/gentoo` or host `repos.conf` for that purpose, and SHALL NOT offer a config key that points at another tree.

#### Scenario: Host tree is not consulted

- **WHEN** the host has a Gentoo tree at `/var/db/repos/gentoo` with different ebuilds from the managed tree
- **THEN** lane ceilings and ensure atom choice reflect the managed tree only

#### Scenario: Host without Portage plans lanes

- **WHEN** `portageq` is not installed on the host and the managed tree is current
- **THEN** `outdated` plans DepsAndAssets lanes without error

### Requirement: Tree comes from the Gentoo git mirror

The program SHALL create the tree as a shallow clone of the `stable` branch of `https://github.com/gentoo-mirror/gentoo.git` and SHALL update it with fetches from that remote, using host `git`. The tree SHALL include `metadata/md5-cache`. The program SHALL NOT use rsync, HTTP snapshots, or `emerge-webrsync` for the managed tree.

#### Scenario: Fresh host clones

- **WHEN** no managed tree exists and a work command needs it
- **THEN** the program creates it with a shallow clone of the mirror's `stable` branch

#### Scenario: Existing tree fetches incrementally

- **WHEN** a managed tree exists and a sync runs
- **THEN** the program fetches from the mirror and does not clone again

### Requirement: Tree identity is the commit id

The identity of the managed tree SHALL be the full commit id checked out in it. The program SHALL read the identity without network access. Consumers that record which tree they used (such as the image sidecar and the check cache) SHALL record this identity.

#### Scenario: Identity after sync

- **WHEN** a sync checks out mirror commit `6966999d2…`
- **THEN** the tree identity reported to consumers is that full commit id

### Requirement: Commits are verified against the pinned mirror key

The program SHALL check out a commit only when host `gpg` reports a valid signature on it whose primary key fingerprint equals the Gentoo repository-mirror key fingerprint built into the program. Verification SHALL use a keyring under the manager cache, not the operator's keyring or agent, and SHALL NOT prompt. A failed verification SHALL hard-fail the sync and leave the tree unchanged.

#### Scenario: Mirror commit is accepted

- **WHEN** the target commit is signed by the Gentoo repository-mirror key
- **THEN** the program checks it out

#### Scenario: Developer commit is rejected

- **WHEN** the target commit is signed by a key other than the pinned mirror key, or is unsigned
- **THEN** the sync hard-fails and the tree stays at its previous commit

#### Scenario: Operator keyring untouched

- **WHEN** a sync verifies a commit
- **THEN** the operator's GnuPG home and agent are not read or modified

### Requirement: Mirror key acquisition and refresh

When the cache keyring lacks the pinned mirror key, the program SHALL fetch it by Web Key Directory or from `keys.gentoo.org` by fingerprint, and SHALL accept only a key whose fingerprint matches the pinned one. Every sync SHALL refresh that key from `keys.gentoo.org`. A failed refresh SHALL warn and continue with the cached key while it is unexpired and not revoked.

#### Scenario: First sync fetches the key

- **WHEN** the cache keyring is empty and a sync runs
- **THEN** the program fetches the mirror key and imports it only if its fingerprint matches the pinned fingerprint

#### Scenario: Refresh failure warns

- **WHEN** the key refresh fails because the keyserver is unreachable and the cached key is valid
- **THEN** the sync proceeds and a warning names the failed refresh

#### Scenario: Revoked key fails

- **WHEN** the refreshed mirror key is revoked
- **THEN** verification fails and the sync hard-fails

### Requirement: Sync target is the newest binhost-aligned mirror commit

A sync SHALL read the `TIMESTAMP` from the host-architecture Gentoo binhost `Packages` index and SHALL target the newest commit on the mirror's `stable` branch that is a mirror metadata commit and whose commit time is at most `TIMESTAMP` minus one hour. Developer commits between mirror metadata commits SHALL NOT be targets.

#### Scenario: Newer commits are skipped

- **WHEN** the binhost `TIMESTAMP` is 12:35 UTC and mirror metadata commits exist at 11:16, 12:30, and 20:31 UTC
- **THEN** the sync targets the 11:16 UTC commit

#### Scenario: Developer commit not chosen

- **WHEN** the newest commit before the cutoff is a developer commit and an earlier mirror metadata commit exists
- **THEN** the sync targets the mirror metadata commit

### Requirement: Alignment failures keep a vouched-for tree

When alignment cannot pick a target, the program SHALL keep the current tree and warn. This applies when the binhost index is unreachable, and when no target exists after deepening the fetch to seven days before `TIMESTAMP`. With no tree yet, the program SHALL use the branch tip with a warning that source builds are possible.

#### Scenario: Binhost unreachable with an existing tree

- **WHEN** the binhost `Packages` index cannot be fetched and a managed tree exists
- **THEN** the tree stays at its commit and a warning names the binhost failure

#### Scenario: Binhost unreachable on a fresh host

- **WHEN** the binhost index cannot be fetched and no managed tree exists
- **THEN** the program clones, checks out the verified branch tip, and warns that image builds may compile from source

#### Scenario: Stalled binhost

- **WHEN** no mirror metadata commit at or before the cutoff exists within seven days before `TIMESTAMP`
- **THEN** an existing tree stays at its commit and a warning says the binhost index appears stalled

### Requirement: Network failure keeps the existing tree

When the mirror cannot be reached, the program SHALL keep an existing tree and warn. It SHALL hard-fail the command when no tree exists.

#### Scenario: Offline with a tree

- **WHEN** a sync is due, `github.com` is unreachable, and a managed tree exists
- **THEN** the command continues with the existing tree and logs a warning

#### Scenario: Offline without a tree

- **WHEN** no managed tree exists and `github.com` is unreachable
- **THEN** the command exits with status `1` naming the failed clone

### Requirement: Configurable tree max age

The program SHALL read optional config key `gentoo-tree-max-age` as a human duration with the same syntax as `check-cache-ttl`, defaulting to six hours. A tree SHALL be due for sync when it is missing or when the last successful sync check is older than the max age. A check that leaves the commit unchanged SHALL count as successful. Invalid durations SHALL fail configuration load.

#### Scenario: Default max age

- **WHEN** config omits `gentoo-tree-max-age` and the last successful sync check was seven hours ago
- **THEN** the next `outdated`, `update`, or `gencache` syncs the tree

#### Scenario: Fresh tree is not synced

- **WHEN** the last successful sync check was one hour ago and no refresh was requested
- **THEN** the command uses the tree without contacting the mirror or binhost

### Requirement: Commands that sync

`outdated`, `update`, and `gencache` SHALL ensure the managed tree exists and SHALL sync it when due, before any work that reads it. `--refresh` on `outdated` or `update` SHALL force a sync regardless of age. `list`, `eclean`, and help SHALL NOT sync or require the tree.

#### Scenario: Refresh forces a sync

- **WHEN** the operator runs `outdated --refresh` with a tree synced ten minutes ago
- **THEN** the program syncs the tree before planning

#### Scenario: list does not sync

- **WHEN** the operator runs `list`
- **THEN** the program does not run `git` or `gpg` for the tree

### Requirement: Sync waits for runs using the tree

A sync SHALL hold an exclusive lock on the managed tree. A command that reads the tree SHALL hold a shared lock on it from its first read until it exits. A due sync SHALL wait until it can take the exclusive lock, and readers SHALL wait for a running sync to finish.

#### Scenario: Sync waits for a running update

- **WHEN** an `update` holds the tree and a second command finds the tree due for sync
- **THEN** the second command waits until the `update` releases the tree, then syncs

#### Scenario: Readers never see a partial checkout

- **WHEN** a sync is checking out a new commit
- **THEN** no other manager command reads the tree until the checkout completes

### Requirement: Free space before the first clone

Before the first clone, the program SHALL check that the cache filesystem has at least 1 GiB free. When it does not, the command SHALL exit with status `1` naming the path, free bytes, and need.

#### Scenario: Insufficient space for the clone

- **WHEN** no tree exists and the cache filesystem has 500 MiB free
- **THEN** the command exits with status `1` before cloning and names the free and needed space
