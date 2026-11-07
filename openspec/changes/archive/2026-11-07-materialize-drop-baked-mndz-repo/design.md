# Design

## Context

See `proposal.md` for motivation. `overlayBindCmds` in `src/Update/Materialize/Recipe.hs` is the only writer of `/etc/portage/repos.conf/mndz.conf`. `runCacheOverlay` bind-mounts the named build context `overlay` at the host checkout path, and the same string is `location` in that file. Qlot, node-gyp, and bun each call it. The Rust `RUN` that emerges `app-portage/pycargoebuild` does not. `materializeCreateArgs` mounts only the unit `work/` and `out/` directories at runtime.

`ensureDefault` skips `docker build` when the image id matches, floors satisfy, and `isGenerator` equals `materializeGeneratorId` (`mndz-overlay-manager-materialize-7`). The recipe already starts with `# syntax=docker/dockerfile:1` and uses BuildKit `--mount`. `buildAndRecord` passes `--build-context overlay=<host checkout>` and an empty context directory. Portage cache ids `mndz-materialize-distfiles`, `mndz-materialize-binpkgs`, and `mndz-materialize-binhost` stay stable across generator bumps.

## Goals / Non-Goals

**Goals:**

- The qlot, node-gyp, and bun emerge `RUN`s see `::mndz` at `/var/db/repos/mndz`.
- No committed layer contains `/etc/portage/repos.conf/mndz.conf`.
- The rendered Dockerfile does not contain the host checkout path.
- A sidecar whose generator is still `mndz-overlay-manager-materialize-7` rebuilds on the next default-tag ensure.

**Non-Goals:**

- Product exclusions in `proposal.md`.
- Changing `materializeCreateArgs`, cache ids, or `package.accept_keywords` contents.
- Rebuilding `mndz-overlay-manager/materialize:local` inside `just check`.

## Decisions

### D1. Mount the repo file from a scratch stage

Emit this stage only when the install list contains qlot, node-gyp, or bun, and place it **before** `FROM gentoo/stage3:…` so the stage3 lineage stays the exported image:

```
FROM scratch AS mndz-repos
COPY <<'EOF' /mndz.conf
[mndz]
location = /var/db/repos/mndz
master = gentoo
auto-sync = no
EOF
```

The heredoc is quoted. Each overlay-bind `RUN` adds:

```
--mount=type=bind,from=mndz-repos,source=/mndz.conf,target=/etc/portage/repos.conf/mndz.conf,ro
```

BuildKit does not commit that mount. Delete the `printf` that writes `mndz.conf`. Keep the `package.accept_keywords` `printf`.

A same-`RUN` `rm` would also leave the file out of the snapshot, and a recipe that dropped the `rm` would ship the warning again. `PORTAGE_REPOSITORIES` would avoid the file too, and it replaces every file under `/etc/portage/repos.conf` for that `emerge`, including `gentoo.conf`. The mount keeps Portage's normal directory and fails the build if the section is missing.

### D2. Fixed container path for the worktree

`runCacheOverlay` mounts `from=overlay,source=/,target=/var/db/repos/mndz,ro`. The host checkout remains the value of `--build-context overlay=…` in `buildAndRecord`. `renderMaterializeDockerfile` drops its host-path argument, and call sites stop passing it. The pure recipe then has no way to embed that path.

Mounting at the host path kept one string for the bind target and `location`. It also stored that path in the image config. `/var/db/repos/mndz` matches `location` and sits beside `::gentoo`.

### D3. Generator `mndz-overlay-manager-materialize-8`

Bump `materializeGeneratorId`. Update tests that hardcode `mndz-overlay-manager-materialize-7`. Floors-and-id skip is unchanged. Cache ids are unchanged, so the rebuild can `usepkg` packages already in the binpkg cache. The first changed `RUN` is the first overlay-bind install; layers before it can stay cached.

## Risks / Trade-offs

- [Scratch stage placed after `FROM gentoo/stage3`] → The exported image would be the scratch stage. The stage is emitted only as a prefix of the stage3 recipe.
- [Heredoc `COPY` needs BuildKit] → The recipe already requires BuildKit for `--mount` and sets the syntax directive. No second opt-in.
- [Bind target `/var/db/repos/mndz` leaves an empty directory in the layer] → Nothing in `repos.conf` points at it after the `RUN`, and Portage does not scan `/var/db/repos` on its own.
- [`just check` stays green while `sha256:e0976cd6…` still has the file] → The generator bump is what makes the next default-tag ensure build. An `MNDZ_MATERIALIZE_IMAGE` override stays inspect-only and does not pick up the recipe.
- [Parent `/etc/portage/repos.conf` missing when the file mount is applied] → The stage3 image has that directory; the current recipe already writes a file there.

## Migration Plan

1. Land the recipe, generator id, tests, and this delta.
2. `just check` is the gate. It does not `docker build`.
3. The operator's next default-tag `update` that ensures the image builds `mndz-overlay-manager-materialize-8` and replaces the image that contains `mndz.conf`. Do not run that `update` in this change.
4. After that build, `docker run --rm --entrypoint ls mndz-overlay-manager/materialize:local /etc/portage/repos.conf/mndz.conf` fails because the file is absent. Today's `sha256:e0976cd6…` is not that image.
5. Rollback is reverting the recipe and moving the generator id again. An override tag is left untouched.
