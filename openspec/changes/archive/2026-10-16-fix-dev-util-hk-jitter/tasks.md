# Tasks

## 1. Edit the ebuild

- [x] 1.1 In mndz-overlay, edit `dev-util/hk/hk-2.6.0.ebuild` in place and add `export AWS_LC_SYS_NO_JITTER_ENTROPY=1` in `src_configure` before `cargo_src_configure --bin hk`, with the comment from design Decision 2. Leave the filename, `Manifest`, `SRC_URI`, `KEYWORDS`, dependencies, and `src_install` unchanged. Verify the ebuild is still named `hk-2.6.0.ebuild`, that path contains the export once, `dev-util/hk/hk-2.6.0-r1.ebuild` does not exist, and `git diff -- dev-util/hk/Manifest` is empty.

## 2. Land the overlay commit

- [x] 2.1 Regenerate `metadata/md5-cache/dev-util/hk-2.6.0` with package-scoped `egencache` for repo `mndz` and package `dev-util/hk`, using the production argv in `Update.Md5Cache` (location pinned to the overlay checkout). Do not commit through the manager `gencache` command. Verify the cache path is still `metadata/md5-cache/dev-util/hk-2.6.0` and its `_md5_` equals `md5sum` of `hk-2.6.0.ebuild`.
- [x] 2.2 Commit the ebuild and that cache file only, in mndz-overlay, subject `dev-util/hk: opt out of aws-lc jitterentropy`, no body. Verify `git show --stat` lists those two paths and does not list `Manifest`.

## 3. Prove the package

- [x] 3.1 Emerge `=dev-util/hk-2.6.0` and verify the merge finishes. Then run `hk --version` and verify it prints `2.6.0`. Do not resume the failed Portage tree at `/var/tmp/portage/dev-util/hk-2.6.0-2026-10-15T22:24:07-07:00`, and do not treat the earlier mise spike as this proof.
- [x] 3.2 Run `openspec validate fix-dev-util-hk-jitter --type change --strict` and verify it passes. No living spec and no Haskell change, so no `hk check` and no spec archive sync.

## Workflow follow-up

- Archive the change after the overlay commit and the emerge smoke are done.
