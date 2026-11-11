# Proposal

## Why

`serialize-pack-xz` gave the single in-flight DepsAndAssets compression `XZ_OPT=-T{N} -9e`, but xz's multi-thread encoder gives each thread one block, and at `-9` the default block is 3 × the 64 MiB dictionary = 192 MiB. A pack therefore uses at most `ceil(uncompressed / 192 MiB)` threads. Most crates tarballs are 250–930 MiB (2–5 blocks), so the "crates pack" step leaves most of `--jobs` idle. `cargo-outdated-0.18.0-crates.tar.xz`, the first crates pack since that change, is 528 MiB uncompressed in 3 blocks: 3 of 8 threads ran.

A measured repack of `usage-7.3.0-crates` (267 MiB, `-T8 -9e`) at 64 MiB blocks was about 2.6× faster than the default block size, for +1.3% bytes. 32 MiB blocks were 4.4× faster for +4.3%.

## What Changes

- When the resolved `--jobs` value `N` is greater than 1, pack compression sets `XZ_OPT=-T{N} -9e --block-size=64MiB`.
- When `N` is 1, `XZ_OPT` stays `-T1 -9e` with no block size. `--jobs 1` keeps the single-thread encoder and its output.
- The block size is a fixed 64 MiB, the same as the `-9` dictionary. It does not depend on `N` or on input size, so multi-thread output for one tree is the same for any `N` greater than 1.
- The rule applies to every pack through the shared helper: Go vendor, npm deps, Bun deps (BunCache and InstallTree), Cargo crates, the rusty_v8 snapshot, SBCL, uv, and Pdm.
- Ecosystem requirements that repeat the literal `XZ_OPT=-T{N} -9e` defer to the shared hermetic pack rule instead of restating the option string.

## Non-goals

- No change to the preset (`-9e` stays), the one-compression-at-a-time slot, or how `N` is resolved. No new CLI flag.
- No block size derived from `N` or from the stage size, and no block size for `-T1`.
- No republish of existing releases. Reuse still keys off release tag and filename and compares downloads to the existing `.sha512` sidecar.
- Cargo per-crate `tar -xzf` staging stays serial. That is a separate follow-up (wiki handoff `cargo-crate-staging-serial-extract-handoff.typ`).
- No change to the rusty_v8 `tar -xJOf` extraction of `v8/DEPS`.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `hermetic-asset-materialize`: The pack xz threads requirement adds `--block-size=64MiB` when `N` is greater than 1. The hermetic tar/xz rule's compression item points to that requirement.
- `go-vendor-assets`: The vendor tarball requirement defers to the hermetic pack rule for `XZ_OPT` instead of restating `-T{N} -9e`.
- `bun-deps-assets`: The InstallTree packaging requirement defers to the hermetic pack rule for `XZ_OPT`.
- `cargo-crates-assets`: The manager-owned crates tarball pack requirement defers to the hermetic pack rule for `XZ_OPT`.
- `sbcl-deps-assets`: The SBCL deps tarball compression requirement defers to the hermetic pack rule for `XZ_OPT`.

## Impact

- `Update.Pack.XzTar.xzOptValue` is the only place that builds the option string. No call site or ops constructor changes.
- Tests in `test/Test/Ecosystems.hs` that pin the exact `-T4 -9e` string learn the block-size suffix. `-T1 -9e` assertions stay.
- Haddock comments that quote `XZ_OPT=-T{N} -9e` in the ecosystem modules are updated.
- New multi-thread packs differ in bytes from `serialize-pack-xz` packs of the same tree: more, smaller blocks, about 1–4% larger.
- Per-thread input buffering drops from about 576 MiB to about 192 MiB, so `-T{N}` peak memory goes down.
- No README, CONTRIBUTING, or AGENTS edit. `XZ_OPT` isn't documented there and the CLI does not change.
