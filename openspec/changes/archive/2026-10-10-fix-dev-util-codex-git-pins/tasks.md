# Tasks

## 1. Template src_prepare

- [x] 1.1 In the overlay `dev-util/codex` ebuild, look up `crossterm`, `tokio-tungstenite`, and `tungstenite` in `GIT_CRATES` and rewrite every matching workspace `[patch.crates-io]` git line to that entry's unpacked path. Point those three checkout checks at the same paths. Verify the ebuild contains no `45fecb9508105988f42fe6ff0441783ed3717f92` and that a missing `GIT_CRATES` key or a missing manifest line still dies.
- [x] 1.2 Add an empty `learning_mode_windows` stub beside the `appcontainer_common` stub and rewrite that workspace git line to the stub. Verify the ebuild writes the stub package and that the `GIT_CRATES` array has neither `learning_mode_windows` nor `appcontainer_common` as a key.

## 2. Revision and cache

- [x] 2.1 Rename the ebuild to `codex-0.162.0-r1.ebuild`. Verify `dev-util/codex/` has that ebuild and no `codex-0.162.0.ebuild`. Leave the overlay uncommitted for an amend of `50da8d5`.
- [x] 2.2 Replace `metadata/md5-cache/dev-util/codex-0.162.0` with the cache entry for `codex-0.162.0-r1`, using the same cache writer this overlay already uses for an ebuild edit. Verify the new file's `_md5_` equals the md5 of the `-r1` ebuild and the unrevisioned cache file is gone.

## 3. Integration

- [x] 3.1 Run `openspec validate fix-dev-util-codex-git-pins --type change --strict` and verify it exits 0.
- [x] 3.2 After `/var/tmp` has 20 GiB free, emerge `=dev-util/codex-0.162.0-r1::mndz` and verify `codex --version` reports `0.162.0`. The operator runs emerge.

## Workflow follow-up

- Amend the ebuild rename and md5-cache into overlay commit `50da8d5` (`dev-util/codex: 0.162.0`). Do not add a second commit.
- Archive this change after that emerge succeeds.
