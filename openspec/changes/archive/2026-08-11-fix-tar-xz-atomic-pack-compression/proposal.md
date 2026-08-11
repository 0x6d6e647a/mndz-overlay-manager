## Why

Manager-owned Cargo pack writes the archive to `${out}.tar.xz.tmp` then renames. GNU `tar -a` keys compression off the **filename suffix**, so `.tmp` produces a **plain tar** labeled `.tar.xz`. That shipped multi‑hundred‑MiB / multi‑GiB “crates” assets (hk 1.54.1, usage 5.1.0, mise 2026.8.3), broke size expectations, and contributed to GitHub upload `ResponseTimeout` on mise 2026.8.4. Other DepsAndAssets packs already emit real XZ but only request `XZ_OPT=-T0 -9`, not extreme `-9e`. We need a correct atomic pack, uniform extreme compression, and tests that published `*.tar.xz` bodies are actually XZ.

## What Changes

- Fix Cargo (and any shared) atomic archive creation so the path passed to `tar -a` (or an equivalent forced xz path) always selects **xz** compression, while keeping atomic final rename semantics.
- Standardize all DepsAndAssets tarball packs (Go vendor, npm deps, Bun deps, Cargo crates, Sbcl/Autolith deps) on **`XZ_OPT=-T0 -9e`** (multi-threaded extreme), not a mix of `-9` and `-9e`.
- After successful pack (before publish treats the file as final), **verify** the artifact is XZ-compressed data (hard-fail with a clear error if the body is plain tar or otherwise not xz).
- Add automated tests that cover: (1) the atomic-temp footgun cannot recur (temp name must not disable xz); (2) produced archives are real XZ; (3) pack invocations use `-T0` and `-9e` (via injectable runner assertions and/or shared helper).
- Operator remediation of already-published bad assets remains a separate handoff (`uncompressed-tar-artifacts-cleanup.md`); this change is code/spec only.

## Non-goals

- Cleaning or re-uploading existing GitHub release assets / overlay Manifest digests (ops handoff).
- Changing release upload timeouts, streaming request bodies, or GitHub API client settings.
- Changing tarball layout (`cargo_home/`, `go-mod/`, `npm-cache/`, etc.) or distfile basenames.
- Forcing recompression of historical good releases that already used `-9`.
- Pure-Haskell xz; system `tar`/`xz` remains the compressor.

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `cargo-crates-assets`: Atomic pack must produce real xz; compression `XZ_OPT=-T0 -9e`; post-pack XZ verification hard-fail; tests.
- `go-vendor-assets`: Pack uses `XZ_OPT=-T0 -9e` (was `-9`); post-pack XZ verification; tests as applicable.
- `npm-deps-assets`: Same uniform `-9e` + XZ verification.
- `bun-deps-assets`: Same uniform `-9e` + XZ verification (BunCache and InstallTree packs).
- `sbcl-deps-assets`: Same uniform `-9e` + XZ verification for deps tarball pack.

## Impact

- Code: `Update.Cargo.Crates` (`createArchiveAtomic`), `Update.Go.Vendor`, `Update.Npm.Cache`, `Update.Bun.Cache`, `Update.Sbcl.Deps`; likely a small shared pack helper for tar+xz+verify.
- Tests: Cargo pack tests mandatory for the `.tmp` bug; other ecosystems assert `XZ_OPT` / magic where they already heat pack paths.
- Runtime: slightly higher pack CPU/wall for non-Cargo ecosystems that move from `-9` to `-9e`; smaller artifacts.
- No CLI/config surface change. No change to package target / PV selection rules.
