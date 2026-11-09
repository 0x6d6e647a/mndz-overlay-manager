# Proposal

## Why

FilmCraft 0.18.0 fails in `src_prepare` because `craft-web-host` is a git dependency only under `filmcraft-web`'s `wasm32` target table, so `GIT_CRATES` omits it. Cargo still resolves that dependency while building the native packages with `--offline --locked`, and the missing checkout aborts the emerge.

## What Changes

- A Cargo GitTag update other than `dev-util/codex` keeps a lock git package that any manifest edge names, including an edge that sits only under a windows-only or wasm-only target table.
- `dev-util/codex` still omits a lock git package whose every manifest edge is windows-only or wasm-only, including `microsoft/mxc` and `appcontainer_common`. Its Windows workspace stubs stay.
- `media-video/filmcraft-0.18.0` fetches `craft-web-host` from craft-libs `2e2312ddaf21bc3d85cd3395d0955c7d239306f6` at `crates/web-host`.
- Dev-dependencies stay outside the edge set. The MSRV and tag-floor `cfg` walk stays as it is. `[patch.*]` pin handling in `mndz-cargo` stays fail-closed.

## Capabilities

### New Capabilities

### Modified Capabilities

- `cargo-crates-assets`: A non-Codex GitTag rewrite keeps a lock git package named only from a wasm or windows target table. Codex still omits that case.
- `storytold-craft-apps`: EffectCraft, and the other Storytold craft apps on this path, keep a git crate named only from a wasm or windows target table.

## Impact

- `stripWindowsOnlyGitCrates` and the GitCrates tests in this repo.
- The next `update` of a non-Codex Cargo GitTag package can add git distfiles that the current omit rule would have dropped.
- Overlay repo `mndz-overlay`: `media-video/filmcraft/filmcraft-0.18.0.ebuild`, its Manifest, and `metadata/md5-cache/media-video/filmcraft-0.18.0`. The distfile is already in the distfiles cache from the sibling craft apps.
- `dev-util/codex` ebuilds and `dev-util-codex-seed` stay on the current omit-and-stub behavior.

## Non-goals

- Packaging the FilmCraft browser build, or adding a USE flag for `craft-web-host`.
- Fetching a git crate that no manifest edge names.
- Changing which `cfg` expressions count as windows-only or wasm-only for the tag-floor walk.
- Stubbing Storytold crates the way Codex stubs `appcontainer_common` and `learning_mode_windows`.
