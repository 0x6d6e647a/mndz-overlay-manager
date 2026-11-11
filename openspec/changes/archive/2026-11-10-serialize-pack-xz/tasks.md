# Tasks

## 1. Compress slot and thread string

- [x] 1.1 Add the thread count argument to `packTarXz` and `packTarXzAtomic`, set `XZ_OPT` to `-T{N} -9e` (`N` at least 1), and take a capacity-1 semaphore around the `tar` invocation in `runTarXz`, including the failure path. Verify with pack tests that count 1 yields `XZ_OPT` exactly `-T1 -9e`, count 4 yields exactly `-T4 -9e`, and the hermetic tar flags are unchanged.
- [x] 1.2 Add a test where two packs share a runner that blocks inside `tar`, and verify the peak number of in-flight `tar` calls is 1 and the second starts only after the first returns.

## 2. Pass the resolved job count through every pack

- [x] 2.1 Thread that `Int` through `mkVendorOps`, `mkNpmCacheOps`, `mkBunCacheOps`, `mkCargoOps`, `mkSbclDepsOps`, `mkUvDepsOps`, and `mkPdmDepsOps`, and pass `aeJobs` from both `Update.Spine` and `withFullPathMaterializeSession`. Update existing pack-test call sites. Verify the ecosystems pack tests still see `XZ_OPT` on the `tar` request, including the docker exec argv case, and that `v8/DEPS` extraction is unchanged.

## 3. Integration check

- [x] 3.1 Run `openspec validate serialize-pack-xz --type change --strict` and verify it exits 0.
- [x] 3.2 Run `just check` and verify the full gate exits 0.

## Workflow follow-up

- Archive the change after review. Archiving syncs the delta specs into `openspec/specs/`. Do not edit those living specs during apply.
