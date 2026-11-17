# Spec Delta

## ADDED Requirements

### Requirement: README documents the smoke command

`README.md` SHALL have a `smoke` section that documents: `PACKAGE...` targets and `--exclude` with an example; that every on-disk version is tested one at a time in a fresh container; the result line and exit status; that `--jobs` sets build parallelism; and that the worktree is tested as it is, including uncommitted changes.

#### Scenario: Operator reads the smoke section

- **WHEN** an operator reads the `smoke` section of `README.md`
- **THEN** it shows an invocation with a package target and one with `--exclude`
- **AND** it states that the exit status is `1` when any run fails

### Requirement: README documents the smoke environment

`README.md` SHALL state that smoke containers hold `SYS_ADMIN` so Portage's sandboxes stay on, that the smoke image is separate from the materialize image, the image tag, the volume names `mndz-smoke-binpkgs` and `mndz-smoke-distfiles` and that removing them is manual, the per-run tree snapshot image, and where run logs are written and how many are kept.

#### Scenario: Operator looks for the volumes

- **WHEN** an operator wants to reclaim smoke disk space
- **THEN** the README names both volumes and states that the manager does not prune them

## MODIFIED Requirements

### Requirement: README runtime table matches host requirements

`README.md` runtime requirements SHALL state: `list` needs neither Portage, GPG, nor Docker; `outdated` needs `git` and `gpg` (for the tree) but not Portage or Docker; `update` and `gencache` need `git`, `gpg`, and `docker` but not host `ebuild`, `egencache`, or `portageq`; the first `update` or `gencache` on a host with no image builds a base-only image; and `smoke` needs `git`, `gpg`, and Docker Engine 28.0 or newer with the containerd image store, and builds its own image on first use.

#### Scenario: Operator reads outdated requirements

- **WHEN** an operator reads the README runtime requirements for `outdated`
- **THEN** it lists `git` and `gpg` and does not list Portage or Docker

#### Scenario: Operator reads smoke requirements

- **WHEN** an operator reads the README runtime requirements for `smoke`
- **THEN** it lists `git`, `gpg`, and `docker`, the minimum Docker Engine version, and the containerd image store
