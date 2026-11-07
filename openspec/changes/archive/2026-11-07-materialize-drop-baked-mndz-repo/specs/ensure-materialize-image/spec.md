# Spec Delta

## ADDED Requirements

### Requirement: Overlay emerge mounts the worktree at a fixed path

When the generated recipe emerges `dev-lang/bun-bin::mndz`, `dev-lisp/qlot::mndz`, or `dev-build/node-gyp::mndz`, that atom's emerge `RUN` SHALL mount the configured overlay worktree read-only at `/var/db/repos/mndz` from the overlay build context. The rendered recipe SHALL use that container path as the mount target. A recipe that emerges none of those atoms SHALL NOT mount `/var/db/repos/mndz`.

#### Scenario: Qlot, node-gyp, and bun RUNs use the fixed path

- **WHEN** the recipe emerges overlay qlot, overlay node-gyp, and overlay bun-bin
- **THEN** each of those emerge `RUN`s mounts the overlay build context read-only at `/var/db/repos/mndz`

#### Scenario: Go-only recipe does not mount the overlay path

- **WHEN** the recipe emerges no overlay atom
- **THEN** the rendered recipe does not mount `/var/db/repos/mndz`

### Requirement: mndz repos.conf lasts only for the overlay emerge RUN

That overlay emerge `RUN` SHALL see a `[mndz]` repos.conf section with `location = /var/db/repos/mndz`, `master = gentoo`, and `auto-sync = no`, for the duration of the `RUN`. The finished image SHALL NOT contain `/etc/portage/repos.conf/mndz.conf`. The recipe SHALL still write package-level `package.accept_keywords` for an overlay atom that is not plain-visible.

#### Scenario: Qlot RUN sees the section and does not bake the file

- **WHEN** the recipe emerges overlay qlot and keyword-accepts that atom
- **THEN** the qlot emerge `RUN` bind-mounts a repos.conf file onto `/etc/portage/repos.conf/mndz.conf`
- **AND** that file contains `location = /var/db/repos/mndz`, `master = gentoo`, and `auto-sync = no`
- **AND** the recipe does not write `/etc/portage/repos.conf/mndz.conf` by shell redirection
- **AND** the recipe still contains that atom's `package.accept_keywords` line

#### Scenario: Recipe with no overlay atom omits the section

- **WHEN** the recipe emerges no overlay atom
- **THEN** the rendered recipe contains no `[mndz]` section

### Requirement: Non-overlay build RUNs do not see mndz

A recipe `RUN` that does not emerge an overlay atom SHALL NOT mount `/var/db/repos/mndz` and SHALL NOT mount a `[mndz]` repos.conf section. The base image `RUN`, the Rust `RUN` that emerges `app-portage/pycargoebuild`, other Gentoo toolchain `RUN`s, and the Portage cache prune `RUN` are such `RUN`s.

#### Scenario: pycargoebuild RUN stays clear of mndz

- **WHEN** the recipe emerges `app-portage/pycargoebuild` and also emerges overlay qlot
- **THEN** the `pycargoebuild` emerge `RUN` does not mount `/var/db/repos/mndz`
- **AND** that `RUN` does not mount `/etc/portage/repos.conf/mndz.conf`
- **AND** the qlot emerge `RUN` mounts both
