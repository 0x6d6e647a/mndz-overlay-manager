# Spec Delta

## MODIFIED Requirements

### Requirement: egencache runner and repositories-configuration

Production cache generation SHALL invoke `egencache` in the Portage tools container specified by `portage-tools-container` with action `--update`, repository name `mndz`, and a `--repositories-configuration` value that defines the `gentoo` repository at the managed Gentoo tree's container path and the `mndz` repository with `location` set to the absolute effective overlay path, so writes target that tree and eclass checksums come from the managed tree regardless of any ambient `repos.conf`. When package atoms are specified, they SHALL be `category/package` form. The runner SHALL be injectable for tests. Failure of `egencache` (non-zero exit) SHALL be a hard failure for the calling unit or command.

#### Scenario: Injected location matches overlay-path

- **WHEN** the effective overlay path is `/tmp/work/mndz-overlay` and the program regenerates cache for `dev-util/crush`
- **THEN** the `egencache` invocation includes `--repo mndz` and `--repositories-configuration` that sets `mndz` location to that absolute path
- **AND** includes `--update` with atom `dev-util/crush` (or full-repo update when no atoms apply)

#### Scenario: egencache failure is hard failure

- **WHEN** `egencache` exits non-zero during `gencache` or an `update` unit
- **THEN** the operation is recorded as a hard failure and is not treated as success

#### Scenario: Eclass checksums come from the managed tree

- **WHEN** the host has its own Gentoo tree with a different `cargo.eclass` and `gencache` regenerates a Cargo package's cache
- **THEN** the written `_eclasses_` checksum matches the managed tree's `cargo.eclass`

## ADDED Requirements

### Requirement: gencache preflight requires git gpg and docker

Before cache mutation, `gencache` SHALL verify that `git`, `gpg`, and `docker` are available on `PATH`, and SHALL NOT require host `egencache`. Missing tools SHALL log an error naming them and exit with status `1`. Signing SHALL NOT be optional for the gencache commit path.

#### Scenario: Missing docker on gencache

- **WHEN** the user runs `gencache` and `docker` is not on `PATH`
- **THEN** the program exits with status `1` before generation

#### Scenario: Host egencache not required

- **WHEN** the user runs `gencache`, `egencache` is not on `PATH`, and `git`, `gpg`, and `docker` are
- **THEN** preflight does not fail because `egencache` is missing

## REMOVED Requirements

### Requirement: gencache preflight tools

**Reason**: `egencache` now runs in the Portage tools container, so host `egencache` is no longer a `gencache` prerequisite and `docker` is.

**Migration**: Replaced by "gencache preflight requires git gpg and docker".
