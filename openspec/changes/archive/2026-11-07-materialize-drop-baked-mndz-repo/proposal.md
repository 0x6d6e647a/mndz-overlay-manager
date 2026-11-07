# Proposal

## Why

The materialize image keeps `/etc/portage/repos.conf/mndz.conf` after the build `RUN` that needed `::mndz`. That file points at the host overlay path, which the finished image does not contain, so every in-container Portage startup warns and drops the repo. Crate materialize does not need `::mndz`; the warning is noise on every `pycargoebuild` run.

## What Changes

- Overlay-bind build `RUN`s (qlot, node-gyp, bun-bin) mount the overlay read-only at `/var/db/repos/mndz` and mount a `[mndz]` repos.conf snippet only for that `RUN`. The snippet's `location` is `/var/db/repos/mndz`.
- The committed image does not contain `/etc/portage/repos.conf/mndz.conf`. The host checkout path stays on the `docker build` `--build-context` and leaves the Dockerfile text.
- Recipes that do not emerge an overlay atom do not carry that snippet.
- `package.accept_keywords` lines for those overlay atoms stay in the image.
- The recipe generator identity advances so a floor-satisfying sidecar still rebuilds once. `just check` proves the Dockerfile text and does not build the image.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `ensure-materialize-image`: An overlay atom is emerged with the worktree visible at `/var/db/repos/mndz` for that build `RUN` only, and the finished image does not keep a `repos.conf` entry for `::mndz`.

## Impact

- `Update.Materialize.Recipe` (overlay-bind `RUN` text and the repo snippet), `Update.Materialize.Sidecar` (generator identity), `test/Test/Ensure.hs`.
- `Ensure.hs` still passes `--build-context overlay=<host checkout>`. Runtime `docker create` mounts stay `work/` and `out/` only.
- Portage cache mount ids stay the same, so a generator rebuild can reuse distfiles and binpkgs.
- README already says the overlay is bind-mounted read-only at build and does not name the container path or `repos.conf`. No README change.
- The live image `mndz-overlay-manager/materialize:local` (`sha256:e0976cd6…`, built 2026-10-25) keeps the stale file until the operator's next default-tag ensure builds. This change does not run that `update`.

## Non-goals

- Rewriting `pycargoebuild` stderr, including the failure headline.
- `pycargoebuild -u` / `--use-crate-tarball`, or passing `--license-mapping` from the manager.
- A runtime bind of the host overlay, a `PORTAGE_REPOSITORIES` override, or a second repos.conf under the unit `work/` directory.
- Copying the overlay git tree into an image layer.
- Pointing `location` at an empty directory so Portage stays quiet.
- Editing the host file `/etc/portage/repos.conf/mndz-devel.conf`.
- Deleting `package.accept_keywords/mndz-*` from the image.
- The filmcraft fetch failure and the `storytold/egui` git pin.
- Running `docker build`, `update`, `sudo`, or `emerge` as part of this change.
