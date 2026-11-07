# Tasks

## 1. Overlay-bind recipe

- [x] 1.1 In `renderMaterializeDockerfile`, when the install list contains qlot, node-gyp, or bun, emit a `FROM scratch AS mndz-repos` stage with a quoted heredoc `COPY` of `[mndz]` (`location = /var/db/repos/mndz`, `master = gentoo`, `auto-sync = no`) before `FROM gentoo/stage3:…`. Point `runCacheOverlay` at `target=/var/db/repos/mndz` and bind-mount `mndz.conf` read-only onto `/etc/portage/repos.conf/mndz.conf` for that `RUN` only. Remove the `printf` that writes `mndz.conf`. Keep `package.accept_keywords` lines. Drop the host-path argument from the renderer and from the `Ensure.hs` call; leave `--build-context overlay=<host checkout>` as it is. Verify with `just test '::mndz|node-gyp|Go-only|SBCL testing|i686 SBCL'`: qlot, node-gyp, and bun `RUN`s still match `from=overlay`, mount `/var/db/repos/mndz` and the conf file, and the conf text has those three fields; the recipe does not redirect onto `/etc/portage/repos.conf/mndz.conf`; a go-only recipe has no `[mndz]` section and does not mount `/var/db/repos/mndz`; a `pycargoebuild` `RUN` mounts neither; existing `package.accept_keywords` assertions still pass.

## 2. Generator identity

- [x] 2.1 Set `materializeGeneratorId` to `mndz-overlay-manager-materialize-8` and update Ensure tests that hardcode `mndz-overlay-manager-materialize-7`. Verify with `just test generator`: a sidecar whose generator differs still `docker build`s in the fake runner, and a successful fake build records `mndz-overlay-manager-materialize-8`. Cache ids `mndz-materialize-distfiles`, `mndz-materialize-binpkgs`, and `mndz-materialize-binhost` stay in the rendered `RUN`s (`just test 'Portage cache|prune RUN'`).

## 3. Gate

- [x] 3.1 Validate the change with `openspec validate materialize-drop-baked-mndz-repo --type change --strict` and run `just check`. `just check` proves the Dockerfile text; it does not rebuild `mndz-overlay-manager/materialize:local`. Do not run `update`, `docker build`, `sudo`, or `emerge`.

## Workflow follow-up

- Archive this change after implementation and review. The delta is the spec update; do not edit the living spec by hand before archive.
- The operator's next default-tag ensure builds the new image. After that build, `docker run --rm --entrypoint ls mndz-overlay-manager/materialize:local /etc/portage/repos.conf/mndz.conf` fails because the file is gone. `sha256:e0976cd6…` is the pre-change image. Do not run that ensure as part of apply.
