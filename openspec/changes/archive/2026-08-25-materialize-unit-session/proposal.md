## Why

Full-path DepsAndAssets materialize wraps **every** builder `CommandRunner` call as `docker run --rm` against the Gentoo materialize image, and binds the **entire run root** rather than that unit’s `work/` and `out/`. Cargo then pays a container create/start/rm for each registry `.crate` extract (`dev-util/mise` is ~1000). On the operator host, `docker run --rm <image> true` is ~25s and `docker exec` is ~32ms, so mise extract is hours of containerd churn at ~0% CPU, not tar work. The hermetic contract is “language work in the image”; the wrap’s **granularity** is the bug.

## What Changes

- **One materialize container session per full-path unit (PV).** Create/start once, `docker exec` each language/`git`/`tar`/`pycargoebuild` command, `docker rm -f` at unit end. Sequential PVs in a package job get sequential sessions. `--jobs` still bounds concurrent **package** jobs (at most that many live sessions).
- **Binds are that unit’s `work/` and `out/` only**, at the same absolute paths the host allocated (already required by `temp-workspace`; implementation today mounts the run root). Sibling unit trees are not visible.
- **Named `--rm` sessions** so operators can `docker stats` / `exec` **while the unit runs**. Deterministic name `mndz-mat-<runId>-<cat>-<pn>-<pv>`. Labels for sweep. No restart policy. `--rm` plus `bracket rm -f`; best-effort sweep of product-labeled leftovers whose owner pid is dead (never hard-fail, never kill another live run).
- **Identity and env match today’s wrap**, moved to session create (`--user` host uid:gid, `HOME=/home/builder`, XDG forced, secrets/`SSH_*`/host `SBCL_*`/`PATH` not forwarded). Per-command cwd/`prEnv`/stdin go on `docker exec`.
- **Cargo progress:** status `staging crates k/N` during extract, then `crates pack` for xz. Step budget stays seven.
- Host spine still owns classify, reuse, publish, GPG, SSH, Manifest. Builders stay Haskell; Docker is a **session + exec prefix**, not a guest worker or generated shell.

**Not BREAKING** for overlay consumers or for the “full path requires docker + image” operator contract.

### Non-goals

- Host-path full-path materialize (`--host-materialize`, unmapped-arch automatic) — seam only so a later change can unwrap the same builders
- Guest materialize binary / second ELF in the image / static linking
- Regenerated shell scripts as the session driver
- Parallel PVs of the same package; unit-level `--jobs`
- Shared `GOCACHE`/`CARGO_HOME` binds or extra cache pinning (per-container XDG is enough)
- Pack `XZ_OPT=-T0` / thread-count policy (sibling handoff)
- Long-lived daemon for the whole `update`; dropping `--rm` so failed containers persist
- Image/generator bump (`sleep infinity` is already in stage3)
- `--init` / tini; changing hermetic pack flags, pycargoebuild, or `--no-write-crate-tarball`
- Making `docker attach` a product feature; keeping containers after unit end for debug (retained unit `work/` stays the artifact)

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `hermetic-asset-materialize`: Full-path language materialize uses **one container session per unit**, not one `docker run` per inner command; `docker exec` for builder commands; session identity/env/user as today; create/start failure or exec into a dead session hard-fails that unit
- `temp-workspace`: Full-path bind-mounts are **only** that unit’s `work/` and `out/` (sibling units and the rest of the run root SHALL NOT be mounted)
- `project-docs`: README notes named `mndz-mat-…` containers for live `docker stats`/`exec` during a full-path unit and that they are removed when the unit ends

## Impact

- **Code**: `Update.Process.Docker` session lifecycle (`create`/`start`/`exec`/`rm -f`) and `withUnitMaterializeSession`; Spine no longer builds one run-root runner for the whole mutate; apply opens a session around each full-path `materializeDistfiles`; cargo status strings; tests record create/start/exec/rm argv (not per-command `docker run`)
- **Operator**: Full-path `update` still needs `docker` + image. Cargo extract wall time drops from hours to seconds of exec plus one ~25s create per unit. Named containers exist only while a unit runs. Leftover sessions from a killed CLI are swept on the next mutate (best-effort)
- **Docs**: README per `project-docs` in the same change
- **Out of tree**: Host-materialize flag remains the existing wiki handoff; pack xz threads remain the pack-slow handoff
