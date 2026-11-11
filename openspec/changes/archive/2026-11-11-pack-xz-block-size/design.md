# Design

## Context

See proposal.md for why. After `serialize-pack-xz`, `Update.Pack.XzTar.xzOptValue n` is the only builder of the xz option string (`"-T" <> show (max 1 n) <> " -9e"`). `withXzOpt` installs it as `XZ_OPT` in the environment that `runTarXz` passes to `tar -cJf`, including through the materialize session's `docker exec`. Every pack (Go vendor, npm, Bun, Cargo crates, rusty_v8 snapshot, SBCL, uv, Pdm) reaches it through `packTarXz` or `packTarXzAtomic` with the resolved `--jobs` count, so changing that one function changes every pack.

xz 5.8.3 reads long options from `XZ_OPT`. `XZ_OPT="-T2 -9e --block-size=1MiB" tar -cJf` on 3 MiB of input produced a 3-block stream.

## Goals / Non-Goals

**Goals:**

- Multi-thread packs (`N > 1`) split input into 64 MiB blocks, so a typical 250–930 MiB pack has 4–15 blocks to spread across threads.
- `N = 1` packs are byte-identical to `serialize-pack-xz` single-thread packs.
- One option builder. No call site, ops constructor, or `ApplyEnv` change.

**Non-Goals:**

- No size-aware or `N`-aware block size. No `--memlimit`, no preset change.
- No progress or slot changes.

## Decisions

### 1. Fixed 64 MiB block size, not derived from N or input size

**Choice:** For `N > 1`, append `--block-size=64MiB` to the option string.

**Why:**

- At `-9` the LZMA2 dictionary is 64 MiB. A 64 MiB block can still use the full dictionary within itself, so the only loss is at block edges. On `usage-7.3.0-crates` that measured +1.3% bytes, against +4.3% for 32 MiB.
- A fixed size keeps multi-thread output independent of `N`: the same tree packed with `-T2` or `-T8` gives the same bytes.
- It needs no `du` of the stage tree before compressing.

**Alternatives:**

- `ceil(size / N)`: always uses N threads, but bytes change with `--jobs`, the size cost grows with N, and the stage tree must be measured before compressing.
- 32 MiB: faster on packs under about 256 MiB, but about three times the size cost.
- Lower preset (`-8e` / `-7e`): also shrinks the block, but cuts the dictionary everywhere. That ties ratio to thread count. `--block-size` changes only parallelism.

### 2. No block size at `-T1`

**Choice:** `xzOptValue n` returns `-T1 -9e` unchanged when `max 1 n == 1`.

**Why:** One thread gains nothing from smaller blocks. Adding a block size would still change `--jobs 1` output and cost bytes. The earlier design keeps `--jobs 1` on the encoder used for existing assets.

### 3. Ecosystem specs defer instead of restating

**Choice:** Go, Bun InstallTree, Cargo crates, and SBCL requirement bodies say `XZ_OPT` comes from the hermetic pack xz threads requirement, instead of quoting `-T{N} -9e`. Their "contains `-T` … and `-9e`" scenarios stay true and are left untouched. npm has no literal in its requirement body and needs no delta.

**Why:** The literal repeated across five specs is why `serialize-pack-xz` needed six deltas. With one source, a later tuning change touches only `hermetic-asset-materialize`.

### 4. Tests pin the string through `xzOptValue`

Most tests already compare `XZ_OPT` with `xzOptValue 4` / `xzOptValue 1`, so they follow the helper automatically. Add direct assertions on the literal values (`xzOptValue 4 == "-T4 -9e --block-size=64MiB"`, `xzOptValue 1 == "-T1 -9e"`, `xzOptValue 0 == "-T1 -9e"`) so the spec values are locked in one place. The hard-coded `-T4 -9e` expectation in `testPackTarXzFourThreads` changes to the new string. The `-T1 -9e` docker-env fixture (`goVersionReq`) only checks that `XZ_OPT` is forwarded and can stay.

## Risks / Trade-offs

- [Risk] New multi-thread packs are 1–4% larger than `serialize-pack-xz` packs. → Accepted. Measured +1.3% at 64 MiB. Small mirrors and downloads are unaffected in practice.
- [Risk] Packs under 512 MiB still have fewer than 8 blocks on an 8-thread run. → Accepted. They finish quickly anyway. Smaller fixed sizes cost more bytes on every pack.
- [Risk] An older xz in the materialize image rejects `--block-size`. → The option has existed since xz 5.1 and Gentoo's image carries current `app-arch/xz-utils`. A pack failure would hard-fail with the `tar` stderr, not produce a bad file.
- [Risk] A re-pack of a PV whose release already exists produces different bytes. → Reuse keys off release tag and filename and compares the download to the existing `.sha512` sidecar, so existing releases are not re-packed.

## Migration Plan

New multi-thread packs pick up the block size on the next `update`. Existing releases stay as published. Rollback is reverting `xzOptValue` and its tests.
