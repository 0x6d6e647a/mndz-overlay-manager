# portage-tools-container Specification

## Purpose

Run Portage `ebuild … manifest` and `egencache` for the overlay inside a container from the materialize image family, against the managed Gentoo tree, so the host needs no Portage installation.

## Requirements

### Requirement: Portage tools run in a container

The program SHALL run every Portage `ebuild … manifest` and `egencache` invocation inside a Portage tools container, not on the host. The program SHALL NOT require host `ebuild`, `egencache`, or `portageq` for any work command.

#### Scenario: Host without Portage regenerates a Manifest

- **WHEN** `update` renames a GitMv ebuild on a host without Portage and `docker` is on `PATH`
- **THEN** `ebuild … manifest` runs in the Portage tools container and the Manifest is written to the overlay

#### Scenario: gencache without host egencache

- **WHEN** the operator runs `gencache` on a host without `egencache`
- **THEN** cache generation runs in the Portage tools container

### Requirement: Tools container image selection

The tools container SHALL use the image recorded as current by the materialize sidecar, or the `MNDZ_MATERIALIZE_IMAGE` tag when that is set. When no image is recorded and no override is set, the program SHALL first ensure a base-only image (no toolchains), as specified by `ensure-materialize-image`.

#### Scenario: Existing image is reused

- **WHEN** `image.json` records an existing image and `update` needs a Manifest before `docker build`
- **THEN** the tools container runs from that recorded image

#### Scenario: Fresh host builds a base-only image

- **WHEN** no image is recorded, no override is set, and `gencache` needs `egencache`
- **THEN** the program builds a base-only image before starting the tools container

### Requirement: One tools container per run

The program SHALL start at most one tools container per command run, on first need, and SHALL run each tool invocation in it. The container SHALL carry the product label and run labels used for materialize sessions, and SHALL be removed when the command exits.

#### Scenario: Several Manifests share one container

- **WHEN** one `update` regenerates Manifests for three packages
- **THEN** all three `ebuild … manifest` invocations run in the same tools container

#### Scenario: Container removed at exit

- **WHEN** the command exits after using the tools container
- **THEN** no tools container from that run remains

### Requirement: Tools container mounts

The tools container SHALL bind the managed tree read-only at `/var/db/repos/gentoo`. It SHALL bind the effective overlay path and the effective manager distfiles path read-write at the same absolute paths as on the host. It SHALL run as the operator's uid and gid with a writable home and a writable `egencache` cache directory. It SHALL NOT receive the GitHub token, GPG agent, or SSH agent.

#### Scenario: Files owned by the operator

- **WHEN** `ebuild … manifest` writes `Manifest` and fetches a distfile in the tools container
- **THEN** both files are owned by the operator's uid and gid on the host

#### Scenario: Tree is read-only

- **WHEN** a tool in the container attempts to write under `/var/db/repos/gentoo`
- **THEN** the write fails and the managed tree is unchanged

### Requirement: Tools container repository configuration

Tool invocations SHALL see a repository configuration in which `gentoo` is at `/var/db/repos/gentoo` and `mndz` is at the effective overlay path with master `gentoo`. That configuration SHALL NOT depend on the host `repos.conf` or profile.

#### Scenario: Overlay eclass resolves

- **WHEN** the tools container generates a Manifest for an overlay ebuild that inherits an overlay eclass
- **THEN** the eclass resolves from the overlay and the Manifest is written

### Requirement: Tool failures keep their existing meaning

A non-zero exit from `ebuild … manifest` or `egencache` in the tools container SHALL be treated exactly as the same failure of a host invocation is treated by `update-apply` and `md5-cache`. A failure to start the tools container SHALL hard-fail every unit that needs it.

#### Scenario: Manifest failure in container

- **WHEN** `ebuild … manifest` exits non-zero in the tools container
- **THEN** the unit hard-fails as specified for a Manifest failure

#### Scenario: Container cannot start

- **WHEN** `docker` cannot create the tools container
- **THEN** units that need Manifest or md5-cache work hard-fail with an error naming the container failure
