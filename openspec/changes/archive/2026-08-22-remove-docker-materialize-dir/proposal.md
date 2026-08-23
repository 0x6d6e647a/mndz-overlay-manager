## Why

`ensure-materialize-image` stopped using an in-repo Dockerfile as the operator or CLI recipe, but left `docker/materialize/README.md` as a pointer. That file only restates the main README, is listed in `extra-source-files`, and still looks like a place to `docker build` from. The pointer should go; operator truth stays in `README.md`.

## What Changes

- Delete the `docker/materialize/` tree (and the empty `docker/` parent if nothing else remains).
- Stop shipping that path via Cabal `extra-source-files`.
- Keep materialize-image operator documentation only in `README.md` (already describes auto-ensure, sidecar, override). Add a short statement that there is no in-repo Dockerfile to build.
- Tests that assert operator copy does **not** name `docker/materialize/Dockerfile` stay as regressions; they do not require the path to exist.

**Not BREAKING** for overlay consumers. Operators who still bookmarked `docker/materialize/` lose a pointer file; behavior of `update` is unchanged.

### Non-goals

- Changing image ensure, sidecar layout, default tag, or `MNDZ_MATERIALIZE_IMAGE`
- Publishing a registry image or restoring a static Gentoo Dockerfile in-tree
- Moving generated sidecar `Dockerfile` (XDG cache) into the git tree

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `project-docs`: README remains the only operator home for materialize-image setup; the repository SHALL NOT ship `docker/materialize/` as a recipe or pointer directory.

## Impact

- **Repo:** delete `docker/materialize/README.md`; drop `extra-source-files` if it only named that file.
- **Docs:** `README.md` (same change).
- **Tests:** no new live Docker; existing “message must not mention in-repo Dockerfile” assertions remain valid.
- **Specs:** `project-docs` delta only.
