# Design

## Context

See proposal.md for why. `Update.Pack.XzTar.runTarXz` is the only `tar -cJf` launch. It sets `XZ_OPT=-T1 -9e` and forwards that environment through `docker exec`. Go, npm, Bun, Cargo crates, the rusty_v8 snapshot, SBCL, uv, and Pdm all call `packTarXz` or `packTarXzAtomic`. Those ops are built in `Update.Spine` and rebuilt with the unit's docker runner in `withFullPathMaterializeSession`. `aeJobs` is already the resolved `--jobs` value (`resolveJobs`: explicit positive `N`, otherwise the host processor count). The package admit semaphore stays that wide for the whole apply, including clone, fetch, install, and crate extraction.

## Goals / Non-Goals

**Goals:**

- One in-flight tar/xz compression per update, taken only around `runTarXz`.
- `XZ_OPT=-T{N} -9e` with `N` equal to `aeJobs`, and `-T1` when `N` is 1.
- Every production pack path and the docker-session rebuild use that same `N`.
- Tests lock the thread string and the one-at-a-time behavior without a shared mutable job count.

**Non-Goals:**

- No change to the package admit pool, reuse lookup, sidecar checks, or `v8/DEPS` `tar -xJOf`.
- No `--memlimit`, no `-T+1`, no thread cap below `N`, no `-T0`.
- No new progress label while a pack waits for the compress slot.
- No README edit. The CLI flag does not change, and the README does not document `XZ_OPT`.

## Decisions

### 1. The slot lives in `runTarXz`

**Choice:** One capacity-1 `QSem` per `update`, created when the apply environment is built and stored there. `withFullPathMaterializeSession` reuses that same sem. `runTarXz` acquires it with `bracket_` around the `tar` invocation, including failure paths. Staging, `tar -xzf` crate extract, clone, and install do not take it. A process-wide `QSem` created with `unsafePerformIO` is rejected: stan flags that as an unsafe anti-pattern. One update owns one sem, which is the spec's scope. Direct pack helpers take the same `QSem` so a caller cannot compress without the lock.

**Alternatives:** Lower the package admit pool to 1 (also serializes network and installs). Take the slot at each ecosystem call site (a new caller can miss it). The rusty_v8 snapshot pack and the crates pack already share `packTarXzAtomic`, so the helper covers both.

### 2. Pass the job count in; do not store it in an `IORef`

**Choice:** `packTarXz` and `packTarXzAtomic` take the thread count. `mkVendorOps`, `mkNpmCacheOps`, `mkBunCacheOps`, `mkCargoOps`, `mkSbclDepsOps`, `mkUvDepsOps`, and `mkPdmDepsOps` take that `Int` and close over it. `Update.Spine` and `withFullPathMaterializeSession` pass `aeJobs`. `xz` options are `"-T" <> show (max 1 n) <> " -9e"`.

**Why not an `IORef`:** Tasty can run cases at the same time. A process-global job count would let one case's `-T4` leak into another. The semaphore has no configuration, so sharing it only serializes packs, which is the product behavior. Each `bracket_` releases it.

**Alternative:** Thread the count only through `ApplyEnv` and have `runTarXz` read it from the `CommandRunner`. The runner is also used for git, npm, and `go`, so the pack helper would have to guess which calls compress. An explicit `Int` on the pack functions is smaller.

### 3. Literal `-T{N}`, including `-T1`

**Choice:** `--jobs 1` stays the single-thread encoder (`-T1`). Any greater `N` is the multi-thread encoder. Do not use `-T+1`. Do not cap `N`.

This matches the settled choices: thread count equals the resolved job count, and a one-job run keeps the encoder used for existing assets.

The delta keeps the existing scenario titles (`XZ is single-thread extreme`, `extreme multi-thread xz`, and `Compression uses multi-threaded extreme xz`). A renamed title is rejected as a dropped scenario. The scenario bodies state `-T` equal to the resolved `--jobs` value.

## Risks / Trade-offs

- [Risk] `-9e` is about 1.25 GiB per thread, so the default processor count can ask for a large compressor. On a host bigger than this 8-core machine that is the whole of `N`, with no cap. → Accepted. `xz` may use fewer threads under its own soft limit. If it also shrinks the dictionary, only that new file's bytes change. Reuse still keys off the release tag and filename, then compares the download to an existing `.sha512` sidecar.
- [Risk] `--jobs 1` and `--jobs` greater than 1 select different encoders, so two packs of the same new tree under those two values differ. Within multi-thread mode, the same preset keeps the same block size unless the dictionary is adjusted. → Accepted. Nothing republishes an existing release to compare.
- [Risk] A progress row can say it is compressing while it waits for the slot. → Accepted for this change. The wait is inside `runTarXz`, which has no progress handle.
- [Risk] The docker session rebuild forgets `aeJobs` and packs with a different `N` than Spine. → Both construction sites take `aeJobs` from the same env. A test feeds `4` and `1` through the helper directly.

## Migration Plan

New full-path packs pick up the rule. Existing GitHub releases stay. Rollback is reverting the helper and the ops constructors; already uploaded assets do not change.

## Open Questions

None.
