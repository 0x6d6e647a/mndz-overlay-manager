## Why

Full-path Cargo materialize spends most of its wall time inside `pycargoebuild` writing `{pn}-{pv}-crates.tar.xz` with single-threaded LZMA `preset=9|PRESET_EXTREME`. Profiling on mise-class trees showed ~85–99% of pycargoebuild time in that step, with no CLI, config, or env lever to change compression. Splitting pack ownership lets the manager keep pycargoebuild for lock-driven fetch, verify, LICENSE+, and GIT_CRATES while packing with multi-threaded system `xz`, matching other DepsAndAssets ecosystems’ use of `XZ_OPT` and cutting the measured bottleneck without a full pycargoebuild replacement.

## What Changes

- Full-path Cargo materialize SHALL invoke `pycargoebuild` with crate-tarball mode **and** `--no-write-crate-tarball`, so pycargoebuild still fetches/verifies crates and inplace-updates the ebuild but does **not** write the xz archive.
- The manager SHALL pack `$DISTDIR` registry crates into `{pn}-{pv}-crates.tar.xz` itself: stage under `cargo_home/gentoo/`, write `.cargo-checksum.json` from **parsed `Cargo.lock` checksums**, then `tar` + `XZ_OPT=-T0 -9e`.
- Spec boundary updates: Haskell owns **crate tarball layout and compression**; pycargoebuild still owns lock-driven fetch, verify, and license/GIT_CRATES ebuild updates (no reimplementation of those in Haskell beyond what packing requires from the lockfile).
- Reuse path unchanged: matching assets still skip both pycargoebuild and the new pack step.
- Operator runtime tools remain `pycargoebuild` + fetcher + `xz` (already required for assets); no new external binary beyond existing preflight.

## Non-goals

- Replacing or forking pycargoebuild for fetch/license logic.
- Persistent shared crate distdir across packages/runs (optional later).
- Broad CPU/job pool or `-T0` oversubscription policy (future resource-scheduling proposal).
- Bit-identical / deterministic tar bitstreams for rebuild reproducibility.
- Aligning compression to non-extreme `-9` only (this change uses `-T0 -9e`).
- Dropping pycargoebuild when LICENSE+ could be frozen from the donor.
- arise integration or a general `hscargoebuild` product.

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `cargo-crates-assets`: Full-path materialize splits pycargoebuild (no-write crate tarball) from manager-owned stage+tar pack; lock parse for pack checksums; compression via `XZ_OPT=-T0 -9e`; “shall not reimplement” boundary narrowed so pack is manager-owned.

## Impact

- **Code:** `Update.Cargo.Crates` (pycargo flags; new pack step after pycargo); likely new helpers for Cargo.lock registry package checksums and staging; tests that mock pycargo and/or pack; space-check headroom for extract + tarball under FullCargo.
- **Specs:** `openspec/specs/cargo-crates-assets` (and change delta).
- **Docs:** Only if README/operator text currently claims pycargoebuild alone writes the crates distfile in a way that becomes false; prefer accuracy without expanding AGENTS. No new runtime tool names.
- **Ops:** Cargo full-path wall time expected to drop sharply on large trees; xz multi-thread may contend with concurrent package jobs (accepted; concurrency policy deferred).
- **Artifacts:** New PVs’ crates tarballs will not match historical pycargo extreme bitstreams; reuse continues to key on published SHA.
