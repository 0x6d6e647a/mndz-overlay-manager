# Tasks

## 1. Retarget the active-image splices

- [x] 1.1 In mndz-overlay, edit `dev-util/autolith/autolith-0.60.0.ebuild` in place (no `-r1`, and no restored `autolith-0.58.0.ebuild`). Replace the active-image entry needle with the 8-space `active-image--toplevel` forms and the existing `relocate-to-live-source-root` call between `platform-setenv` and `restart-case`. Replace the `save-lisp-and-die` / `#'active-image-main` needle with an exact-once insert of the no-argument `stash-dump-source-root` call as the first body form of `active-image--prepare-saver`. Leave the four recovery and build-script splices unchanged. Verify with a read-only count against the unpacked `0.60.0` tree: the two new needles match once, the two old needles match zero, and the other four still match once.

## 2. Land and prove the package

- [x] 2.1 Regenerate `metadata/md5-cache/dev-util/autolith-0.60.0` and verify its `_md5_` equals the MD5 of the edited ebuild. Commit that cache file and the ebuild only, with subject `dev-util/autolith: fix 0.60.0 image entry splice`. Verify `git show --stat` lists those two paths and does not list `Manifest`.
- [x] 2.2 Emerge `=dev-util/autolith-0.60.0` and verify the merge finishes with both cores and both `manifest.sexp` files produced. Then run `timeout 5 autolith </dev/null` and verify it does not mention `/var/tmp/portage` or a missing fff helper. `autolith --version` may be run in addition; it is not the proof.
- [x] 2.3 Run `openspec validate fix-autolith-active-image-splice --type change --strict` and verify it passes. No living spec and no Haskell change, so no `hk check` and no spec archive sync.

## Workflow follow-up

- Archive the change after the overlay commit and the emerge smoke are done.
