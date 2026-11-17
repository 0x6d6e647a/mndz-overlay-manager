# Spec Delta

## Purpose

Provide a minimal Gentoo image, separate from the materialize image, that `smoke` containers start from, so installs are tested against a clean system with nothing extra installed.

## ADDED Requirements

### Requirement: Smoke uses its own image

`smoke` containers SHALL start from the image tagged `mndz-overlay-manager/smoke:local`. `smoke` SHALL NOT start containers from the materialize image, and `MNDZ_MATERIALIZE_IMAGE` SHALL NOT affect `smoke`. `outdated`, `update`, and `gencache` SHALL NOT build or use the smoke image.

#### Scenario: Materialize override is ignored

- **WHEN** `MNDZ_MATERIALIZE_IMAGE` is set and the operator runs `smoke`
- **THEN** smoke containers are created from `mndz-overlay-manager/smoke:local`

#### Scenario: Update does not build it

- **WHEN** the operator runs `update` on a host with no smoke image
- **THEN** no smoke image is built

### Requirement: Smoke image contents are minimal

The generated recipe SHALL start from the official `gentoo/stage3` glibc OpenRC flavor for the host architecture, pinned by digest. It SHALL upgrade Portage, run `emerge --update --deep --newuse @world`, and install `sys-process/time`. It SHALL NOT install language toolchains, fetch tools, version-control tools, or any overlay package.

#### Scenario: No toolchains

- **WHEN** the smoke image is built
- **THEN** a container from it has no `go`, `node`, `bun`, `cargo`, or `sbcl` on `PATH`

#### Scenario: GNU time is present

- **WHEN** the smoke image is built
- **THEN** `/usr/bin/time --version` in a container from it identifies GNU Time

### Requirement: Smoke image builds read the managed tree

Each recipe `RUN` that invokes Portage SHALL bind the managed Gentoo tree read-only at `/var/db/repos/gentoo` from a build context that excludes the tree's git metadata. The recipe SHALL NOT run a tree sync, and the built image SHALL NOT contain a Gentoo tree.

#### Scenario: No baked tree

- **WHEN** the smoke image is built
- **THEN** a container from it without a tree mount has no ebuilds under `/var/db/repos/gentoo`

### Requirement: Smoke image recipe leaves Portage sandboxes on

The recipe SHALL NOT remove `sandbox`, `usersandbox`, `userpriv`, `network-sandbox`, `ipc-sandbox`, or `pid-sandbox` from `FEATURES`, in the image environment or in Portage configuration files.

#### Scenario: Default sandbox features

- **WHEN** `portageq envvar FEATURES` runs in a container from the smoke image
- **THEN** the output includes `network-sandbox`, `ipc-sandbox`, `pid-sandbox`, `sandbox`, `usersandbox`, and `userpriv`

### Requirement: Smoke image build does not share Portage caches with materialize

Portage download and binary-package caches used while building the smoke image SHALL be distinct from the caches used by the materialize image build.

#### Scenario: Distinct cache identities

- **WHEN** the generated smoke recipe and the generated materialize recipe are compared
- **THEN** no build cache mount identity appears in both

### Requirement: Smoke image sidecar

After a successful build the program SHALL record the image in `<cache>/mndz/overlay-manager/smoke/image.json`, with the image id, tag, recipe generator identity, stage3 digest, managed tree commit, build time, and last base check time. The last generated recipe SHALL be kept next to it.

#### Scenario: Sidecar after first build

- **WHEN** `smoke` builds the image on a host with no smoke image
- **THEN** `smoke/image.json` exists and records the image id and the stage3 digest it was built from

### Requirement: When the smoke image is built

`smoke` SHALL build the image when no image is recorded, when the recorded image id no longer exists in Docker, when the recorded generator identity differs from the program's, or when the base check finds a different stage3 digest. Otherwise it SHALL reuse the recorded image. A changed managed tree commit alone SHALL NOT cause a build.

#### Scenario: Recorded image is reused

- **WHEN** the recorded image exists, its generator identity matches, and the base check is not due
- **THEN** `smoke` does not run `docker build`

#### Scenario: Tree moved

- **WHEN** only the managed tree commit differs from the one in the sidecar
- **THEN** `smoke` does not run `docker build`

#### Scenario: Recipe changed

- **WHEN** the sidecar's generator identity differs from the program's
- **THEN** `smoke` builds a new image before any run

### Requirement: Smoke image base freshness check

When `materialize-base-check-interval` has passed since the smoke sidecar's last base check, `smoke` SHALL read the current digest of the stage3 tag from the registry without pulling. A different digest SHALL cause a build from the new digest. The same digest SHALL record the check time. A failed request SHALL keep the image, warn, and leave the check due.

#### Scenario: Newer stage3

- **WHEN** the check is due and the registry digest differs from the recorded one
- **THEN** `smoke` builds a new image from the new digest

#### Scenario: Registry unreachable

- **WHEN** the check is due and the registry request fails
- **THEN** `smoke` keeps the image, logs a warning, and continues

### Requirement: Smoke image failures stop the command

A host architecture with no official stage3 flavor, a failed `docker build`, or a registry failure on a host with no recorded image SHALL make `smoke` exit with status `1` before any run, with an error naming the cause.

#### Scenario: Build fails

- **WHEN** `docker build` of the smoke image exits non-zero
- **THEN** `smoke` exits with status `1` and no run is performed

### Requirement: Previous smoke image is removed

After a successful build that replaces a recorded image, the program SHALL remove the previous smoke image when no container uses it. It SHALL NOT remove the materialize image or prune the build cache.

#### Scenario: Rebuild leaves one smoke image

- **WHEN** a new smoke image is built after a stage3 digest change
- **THEN** the previous smoke image id no longer exists in Docker
- **AND** the materialize image is unchanged
