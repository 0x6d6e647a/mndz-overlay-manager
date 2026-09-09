## Why

`add-dev-util-codex` specified pin-keyed rusty_v8 harvest on Cargo GitTag full-path, but apply never calls it: a helper is unit-tested in isolation, seed was manual, and 0.153.4 “reused” 150.4.0 only by copying extra `SRC_URI` lines. The snapshot is published as a fake overlay atom (`dev-util/rusty-v8`, GitHub title `dev-util/rusty-v8-150.4.0`) even though there is no such ebuild. A real `v8` pin move would not clone, would not rewrite `RUSTY_V8_VER`, and would keep 150.4.0 Chromium clang/rust-toolchain GCS filenames.

## What Changes

- Wire rusty_v8 harvest onto **Codex** (`dev-util/codex`) full-path apply: parse the lock’s crates.io `v8` pin, reuse a verified `rusty-v8-${ver}` snapshot or clone `denoland/rusty_v8` `v${ver}` with recursive submodules, pack, and publish. Other Cargo GitTag packages (hk, mise, usage, biodiff) SHALL NOT harvest even if a future lock grew a `v8` pin.
- Publish identity is pin-keyed and **not** an overlay atom: tag and GitHub release name `rusty-v8-${ver}`, sidecars under assets-root `rusty-v8/`, commit `rusty-v8: ${ver}`. The snapshot is **not** an extra asset on `codex-${PV}`.
- Manager writes `RUSTY_V8_VER` and the rusty-v8 `SRC_URI` tag from the lock. `parameterizeAssetsSrcUri` continues to leave `rusty-v8-` tags unrewritten.
- On pin change, parse `v8/DEPS` GCS `Linux_x64` objects (`host_os == "linux"`) and rewrite `CLANG_DIST` / `RUST_TC_DIST`. Same pin copies donor GCS lines. Chromium clang/rust-toolchain stay Portage GCS distfiles, not overlay-assets.
- Codex crates `requiredAssetBasenames` stay crates-only. Missing rusty-v8 MUST NOT make an existing `codex-${PV}` release partial. Lookup is assets-worktree checksums **and** GitHub tag `rusty-v8-${ver}`.
- Operator cleanup on **mndz-overlay-assets** (not a git rebase of `cfd53b4`): move tag `codex-0.153.3` onto `d4aed56`; PATCH GitHub release title to `rusty-v8-150.4.0`; `git mv` sidecars to `rusty-v8/` with commit `rusty-v8: 150.4.0`. Overlay `-rN` only if ebuild text or distfiles change (this cleanup should not). Rewording `cfd53b4` is out of band.

## Non-goals

- Attaching rusty-v8 to a `codex-${PV}` GitHub release.
- Overlay package `dev-util/rusty-v8` or `dev-libs/rusty-v8`.
- Rewriting `cfd53b4`’s git commit message (operator, off-book).
- Replacing Chromium GCS clang/rust-toolchain with Gentoo clang/rustc.
- Prebuilt `librusty_v8`.
- CLI, config, quality-pipeline, or agent-process surface changes (no README/CONTRIBUTING/AGENTS update).

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `cargo-crates-assets`: Harvest runs on Codex apply (not helper-only); Codex-only until a second consumer; `RUSTY_V8_VER` is manager-owned; GCS filenames from `v8/DEPS` on pin change; rusty-v8 is a separate release lookup, not a crates-tag companion.
- `assets-publish`: Pin-keyed rusty-v8 publish identity without `{category}/{package}` (tag/name `rusty-v8-${ver}`, sidecars `rusty-v8/`, commit `rusty-v8: ${ver}`); `target_commitish` must be the sidecar commit.
- `dev-util-codex-seed`: Seed/overlay truth uses the pin-keyed tag and `rusty-v8/` sidecars, not `dev-util/rusty-v8`; GCS lines track the lock pin.

## Impact

- Manager: `Update.Apply.Materialize` (Codex full-path companion harvest/publish), `Update.Cargo.Crates` (recursive clone, DEPS parse, `RUSTY_V8_VER` rewrite), `Update.Assets.Layout` / `Release` (non-overlay identity), `Update.Adequacy` (crates-only required basenames for Codex), tests and a 150.4.0 `v8/DEPS` excerpt fixture.
- Assets repo: sidecar directory, GitHub release title, `codex-0.153.3` tag target.
- Overlay: no `-rN` for cleanup; later Codex full-path writes `RUSTY_V8_VER` / GCS from lock+DEPS.
- Quality: `hk check`. No operator CLI.
