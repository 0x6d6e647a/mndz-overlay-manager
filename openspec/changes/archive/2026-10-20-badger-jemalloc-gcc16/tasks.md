# Tasks

## 1. Publish the revision

- [x] 1.1 In mndz-overlay, `git mv` `dev-db/badger/badger-4.9.6.ebuild` to `badger-4.9.6-r1.ebuild`. Copy `/var/db/repos/gentoo/dev-libs/jemalloc/files/jemalloc-5.3.0-dont-call-libstdcxx-internals.patch` unchanged to `dev-db/badger/files/jemalloc-5.3.0-dont-call-libstdcxx-internals.patch`. Inside the `USE=jemalloc` `pushd` of `${WORKDIR}/jemalloc-5.3.0`, before `econf`, add the comment and `eapply "${FILESDIR}/jemalloc-5.3.0-dont-call-libstdcxx-internals.patch"` from design Decision 2. Leave `Manifest`, `SRC_URI`, `PATCHES`, `KEYWORDS`, dependencies, and the ristretto `sed` unchanged. Verify `badger-4.9.6.ebuild` is gone, the `-r1` ebuild contains that `eapply` once and does not set `PATCHES`, `cmp` of the new patch against the Gentoo file is empty, and `git diff -- dev-db/badger/Manifest` is empty.

## 2. Land the overlay commit

- [x] 2.1 Regenerate md5-cache with package-scoped `egencache` for repo `mndz` and package `dev-db/badger`, using the production argv in `Update.Md5Cache` (location pinned to the overlay checkout). Do not commit through the manager `gencache` command. Remove `metadata/md5-cache/dev-db/badger-4.9.6` if `egencache` leaves it. Verify the cache path is `metadata/md5-cache/dev-db/badger-4.9.6-r1`, the `badger-4.9.6` cache file is gone, and `_md5_` equals `md5sum` of `badger-4.9.6-r1.ebuild`.
- [x] 2.2 Commit the `-r1` ebuild, the new patch, and the cache rename only, in mndz-overlay, subject `dev-db/badger: 4.9.6-r1`, no body. Verify `git show --stat` lists those paths, does not list `Manifest`, and the subject matches. The overlay hook GPG-signs the commit.

## 3. Prove the package

- [x] 3.1 Do not run `emerge` or `sudo`, and do not resume `/var/tmp/portage/dev-db/badger-4.9.6-2026-10-20T17:17:07-07:00`. Hand the operator `emerge -av1 =dev-db/badger-4.9.6-r1`. The task is done when that merge finishes, `badger --help` prints a command listing, and `strings /usr/bin/badger | grep je_malloc_stats_print` matches.
- [x] 3.2 Run `openspec validate badger-jemalloc-gcc16 --type change --strict` and verify it passes. No living spec and no Haskell change, so no `hk check` and no spec archive sync.

## Workflow follow-up

- Archive the change after the overlay commit and the emerge smoke are done.
