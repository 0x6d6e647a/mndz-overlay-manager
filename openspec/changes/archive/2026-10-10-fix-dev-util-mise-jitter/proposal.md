# Proposal

## Why

`dev-util/mise-2026.10.5` dies in `src_compile` on `aws-lc-sys` 0.45.0. Portage `-O2` is applied after that crate's `-O0` for `jitterentropy-base.c`, `cc` 1.6 has already snapshotted `CFLAGS`, and the source `#error`s when `__OPTIMIZE__` is set. `mise` still builds `aws-lc` under `--no-default-features --features native-tls` because `aube` depends on `reqwest/rustls`. The installed package is `2026.10.3`. `2026.10.5` is committed and never merged.

## What Changes

- Rename the live ebuild to `mise-2026.10.5-r1.ebuild`. Do not leave `mise-2026.10.5.ebuild` in the tree.
- In `src_configure`, export `AWS_LC_SYS_NO_JITTER_ENTROPY=1` beside `OPENSSL_NO_VENDOR=1` and `ZSTD_SYS_USE_PKG_CONFIG=1`.
- Move `metadata/md5-cache/dev-util/mise-2026.10.5` to `mise-2026.10.5-r1` and refresh `_md5_` for the new ebuild bytes.

## Non-goals

- No manager Haskell, no new apply rewrite fields, and no crates-tarball republish.
- No patch of `aws-lc-sys`, `cc`, `aube`, or `mise` inside the crates tarball, and no stripping of `-O*` from `CFLAGS`.
- No KEYWORDS, `RUST_MIN_VER`, `LICENSE`, `SRC_URI`, dependency, or USE change.
- No new mise PV, and no second revision beyond `-r1`.
- No living-spec delta. `cargo-crates-assets` already requires `DepsAndAssets Cargo` for `dev-util/mise` with GitHub `jdx/mise` and tag prefix `v`. `pycargoebuild --inplace` rewrites `CRATES` and `LICENSE` only, so this `src_configure` export stays on the next bump. `skip_specs: true`.
- No `README.md`, `CONTRIBUTING.md`, or `AGENTS.md` edit. Operator CLI, config, and the quality pipeline do not change.

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- (none — `skip_specs: true`)

## Impact

- **mndz-overlay:** `dev-util/mise/mise-2026.10.5.ebuild` renamed to `mise-2026.10.5-r1.ebuild`, and `metadata/md5-cache/dev-util/mise-2026.10.5` renamed to `mise-2026.10.5-r1`. `thin-manifests` and `${P}`/`${PV}` (revision excluded) leave `Manifest` `DIST` lines unchanged. One overlay commit of those two paths.
- **mndz-overlay-assets:** none.
- **mndz-overlay-manager:** planning artifacts only. No Haskell. The next `update dev-util/mise` copies this ebuild body. `groupNewest` prefers the revision over an unrevisioned ebuild of the same PV.
- **Operator:** `emerge =dev-util/mise-2026.10.5-r1`, then `mise --version` prints `2026.10.5`. An unsandboxed offline release build with this export already finished and printed that version; the emerge is the sandbox and `src_install` proof.
