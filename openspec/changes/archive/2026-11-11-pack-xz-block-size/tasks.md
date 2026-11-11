# Tasks

## 1. Block size in the xz option string

- [x] 1.1 Change `Update.Pack.XzTar.xzOptValue` so `max 1 n > 1` yields `-T{n} -9e --block-size=64MiB` and `max 1 n == 1` yields `-T1 -9e`. Update the module and `xzOptValue` Haddock to describe the block size. Verify with a new test asserting `xzOptValue 4 == "-T4 -9e --block-size=64MiB"`, `xzOptValue 8 == "-T8 -9e --block-size=64MiB"`, `xzOptValue 1 == "-T1 -9e"`, and `xzOptValue 0 == "-T1 -9e"`.
- [x] 1.2 Update `testPackTarXzFourThreads` in `test/Test/Ecosystems.hs` to expect `-T4 -9e --block-size=64MiB` for 4 threads and keep `-T1 -9e` for the clamped 0 case. Rename the `-T4 -9e` test label to match. Verify `just coverage XzTar` (or the matching pattern) passes, and that the tests that compare against `xzOptValue 4` / `xzOptValue 1` still pass unchanged.
- [x] 1.3 Only `testPackTarXzHermetic` runs the real `tar`, and only at 1 thread. Add a sibling test that packs a small tree through `productionCommandRunner` with 2 threads, so `XZ_OPT` carries `--block-size=64MiB`. Verify `packTarXz` returns `Right`, `verifyXzFile` passes, and the recorded `XZ_OPT` equals `xzOptValue 2`. This proves the host `tar`/`xz` accept the long option through `XZ_OPT`.

## 2. Haddock references to the old string

- [x] 2.1 Update the `XZ_OPT=-T{N} -9e` Haddock comments in `src/Update/Go/Vendor.hs`, `src/Update/Npm/Cache.hs`, `src/Update/Bun/Cache.hs`, `src/Update/Cargo/Crates.hs` (both), `src/Update/Sbcl/Deps.hs`, `src/Update/Uv/Deps.hs`, and `src/Update/Pdm/Deps.hs` to point at `xzOptValue` (thread count `N`, block size when `N > 1`) instead of restating the string. Verify `grep -rn 'XZ_OPT=-T{N} -9e' src` returns nothing.

## 3. Integration check

- [x] 3.1 Run `openspec validate pack-xz-block-size --type change --strict` and verify it exits 0.
- [x] 3.2 Run `just check` and verify the full gate exits 0.

## Workflow follow-up

- Archive the change after review. Archiving syncs the delta specs into `openspec/specs/`. Do not edit those living specs during apply.
- Optional after archive: on the next real `update` with `--jobs` greater than 1, check a new crates tarball with `xz --robot -l` and confirm the block count is about `ceil(uncompressed / 64 MiB)`.
