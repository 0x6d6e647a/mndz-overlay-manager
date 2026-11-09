# Tasks

## 1. Manager omit gate

- [x] 1.1 Pass the ebuild package name into `stripWindowsOnlyGitCrates`. For `codex`, drop a lock git package whose every manifest edge is windows-only or wasm-only. For every other package name, drop none of those packages. Dev-dependencies stay non-edges. Verify with `just test GitCrates`: the Codex fixture still drops `mxc` and a wasm-only crate, and a non-Codex package name keeps both.
- [x] 1.2 Run `just check` and verify it exits 0 (ormolu, release build, coverage, hlint, stan, weeder).

## 2. FilmCraft checkout

- [x] 2.1 In `mndz-overlay`, add `craft-web-host` to `media-video/filmcraft/filmcraft-0.18.0.ebuild` `GIT_CRATES` for craft-libs `2e2312ddaf21bc3d85cd3395d0955c7d239306f6` at `craft-libs-%commit%/crates/web-host`, and add that archive's existing Manifest DIST line. Verify the ebuild key and the Manifest DIST filename both name that commit.
- [x] 2.2 Regenerate `metadata/md5-cache/media-video/filmcraft-0.18.0` with `egencache --update --repo mndz media-video/filmcraft`. Verify the cache `SRC_URI` contains `craft-libs-2e2312ddaf21bc3d85cd3395d0955c7d239306f6.gh.tar.gz`.

## 3. Change validation

- [x] 3.1 Run `openspec validate keep-target-table-git-crates --type change --strict` and verify it exits 0.

## Workflow follow-up

- The operator re-emerges `media-video/filmcraft` in a new work directory. The failed directory still has `[patch.*]` paths that point at a removed Portage directory.
- Archive this change after review. Sync the deltas into `openspec/specs/` at archive. The `grok-off-leash` stashes may seed the code and overlay edits. Leave their living-spec hunks out of `openspec/specs/` until then.
