## Context

See `proposal.md` for motivation. After `ensure-materialize-image`, Haskell renders the Dockerfile into the XDG sidecar. `docker/materialize/README.md` is a leftover pointer (task 5.2 allowed delete *or* pointer). Cabal `extra-source-files` still ships that file. Operator copy already lives in `README.md`.

## Goals / Non-Goals

**Goals:**

- Remove `docker/materialize/` from the git tree and package extras.
- Keep operator materialize-image documentation only in `README.md`.

**Non-Goals:**

- Changing ensure, sidecar path, default tag, or override env.
- Restoring a static in-tree Dockerfile.

## Decisions

### D1: Delete the tree; do not keep a pointer

**Choice:** Remove `docker/materialize/README.md` and the empty `docker/` parent. Do not replace it with another stub.

**Why:** A pointer still looks like a recipe home and duplicates `README.md`.

**Alternatives:** Keep the README as “go read README.md” — rejected (this change’s problem).

### D2: Drop `extra-source-files` when empty

**Choice:** If `extra-source-files` only listed `docker/materialize/README.md`, remove the field. Do not invent a placeholder extra.

**Why:** Cabal extras were only shipping the pointer.

### D3: README one-line negative

**Choice:** In the existing Materialize image section, state there is no in-repo Dockerfile to `docker build`. Do not re-host the deleted pointer’s default-tag/sidecar list (already present).

**Why:** `project-docs` accuracy: operators should not hunt `docker/`.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Old bookmarks to `docker/materialize/` 404 | README is the documented home |
| Tests still mention the path as forbidden operator copy | Keep those assertions; they do not need the directory |

## Migration Plan

- Delete files; Cabal no longer packages them.
- Rollback: restore the pointer README (not the old Gentoo Dockerfile).

## Open Questions

None.
