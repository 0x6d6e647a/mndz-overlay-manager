# Tasks

## 1. Publish the revision ebuild

- [x] 1.1 In mndz-overlay, `git mv` `dev-util/mise/mise-2026.10.5.ebuild` to `dev-util/mise/mise-2026.10.5-r1.ebuild` and add `export AWS_LC_SYS_NO_JITTER_ENTROPY=1` in `src_configure` immediately after `ZSTD_SYS_USE_PKG_CONFIG=1`, with the comment from design Decision 2. Leave `Manifest`, `SRC_URI`, `KEYWORDS`, dependencies, and `src_install` unchanged. Verify the unrevisioned ebuild path is gone, the `-r1` file contains that export once, and `git diff -- dev-util/mise/Manifest` is empty.

## 2. Land the overlay commit

- [x] 2.1 Remove `metadata/md5-cache/dev-util/mise-2026.10.5` and regenerate the cache with package-scoped `egencache` for repo `mndz` and package `dev-util/mise`, using the production argv in `Update.Md5Cache` (location pinned to the overlay checkout). Verify `metadata/md5-cache/dev-util/mise-2026.10.5-r1` exists, the old cache path is gone, and its `_md5_` equals `md5sum` of `mise-2026.10.5-r1.ebuild`.
- [x] 2.2 Commit the `-r1` ebuild and that cache file only, in mndz-overlay, subject `dev-util/mise: 2026.10.5-r1`, no body. Verify `git show --stat` lists those two paths and does not list `Manifest`.

## 3. Prove the package

- [x] 3.1 Emerge `=dev-util/mise-2026.10.5-r1` and verify the merge finishes. Then run `mise --version` and verify it prints `2026.10.5`. Do not treat the earlier unsandboxed spike, or the preserved Portage work directory, as this proof.
- [x] 3.2 Run `openspec validate fix-dev-util-mise-jitter --type change --strict` and verify it passes. No living spec and no Haskell change, so no `hk check` and no spec archive sync.

## Workflow follow-up

- Archive the change after the overlay commit and the emerge smoke are done.
