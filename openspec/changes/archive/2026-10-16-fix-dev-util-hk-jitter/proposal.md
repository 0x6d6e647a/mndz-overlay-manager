# Proposal

## Why

`dev-util/hk-2.6.0` dies in `src_compile` on `aws-lc-sys` 0.45.0. `cc` 1.8.0 snapshots Portage `CFLAGS` (`-O2`) on the first jitterentropy `cc::Build` flag probe, the crate's later rewrite of those variables to `-O0` never reaches gcc, and `jitterentropy-base.c` `#error`s. Installed `hk-2.5.0` vendors the same `aws-lc-sys` 0.45.0 with `cc` 1.5.1, which still reads `CFLAGS` live, so that emerge succeeded. `2.6.0` is committed and never merged.

## What Changes

- Edit `dev-util/hk/hk-2.6.0.ebuild` in place. Do not add a revision, and do not leave a second ebuild of this PV.
- In `src_configure`, export `AWS_LC_SYS_NO_JITTER_ENTROPY=1` before `cargo_src_configure --bin hk`.
- Refresh `_md5_` in the existing `metadata/md5-cache/dev-util/hk-2.6.0`.

## Non-goals

- No manager Haskell, no new apply rewrite fields, and no crates-tarball republish.
- No patch of `aws-lc-sys`, `cc`, `pklr`, or `hk` inside the crates tarball, and no stripping of `-O*` from `CFLAGS`.
- No `-r1`. `2.6.0` never installed, and the installed package is `2.5.0`.
- No KEYWORDS, `RUST_MIN_VER`, `LICENSE`, `SRC_URI`, dependency, or USE change.
- No new hk PV.
- No living-spec delta. `cargo-crates-assets` already requires `DepsAndAssets Cargo` for `dev-util/hk` with GitHub `jdx/hk` and tag prefix `v`. `pycargoebuild --inplace` rewrites `CRATES` and `LICENSE` only, so this `src_configure` export stays on the next bump. `skip_specs: true`.
- No `README.md`, `CONTRIBUTING.md`, or `AGENTS.md` edit. Operator CLI, config, and the quality pipeline do not change.
- No opt-out added to other cargo packages in this change. `dev-util/mise` already exports the variable.

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- (none — `skip_specs: true`)

## Impact

- **mndz-overlay:** `dev-util/hk/hk-2.6.0.ebuild` and `metadata/md5-cache/dev-util/hk-2.6.0`. `thin-manifests` leaves `Manifest` `DIST` lines unchanged. One overlay commit of those two paths.
- **mndz-overlay-assets:** none.
- **mndz-overlay-manager:** planning artifacts only. No Haskell. The next `update dev-util/hk` copies this ebuild body.
- **Operator:** `emerge =dev-util/hk-2.6.0`, then `hk --version` prints `2.6.0`.
