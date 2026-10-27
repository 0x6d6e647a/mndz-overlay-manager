# Tasks

## 1. Retarget the drifted recovery splices

- [x] 1.1 In mndz-overlay, edit `dev-util/autolith/autolith-0.67.2.ebuild` in place (no `-r1`). Update the `recovery/runtime.lisp` save needle and its replacement so `:toplevel` is followed by four spaces, then `#'recovery-main`, and keep the existing `stash-dump-source-root` call immediately before `save-lisp-and-die`. Replace the `script/build-recovery.lisp` needle with the 13-space `load-recovery-source` block that quickloads serapeum, exports `RECOVERY-MAIN` and `RECOVERY-IMAGE-SAVE`, and loads `recovery/runtime.lisp`. The replacement loads `script/gentoo-fhs.lisp`, installs the compile-namestring hook, and wraps that runtime load with `call-with-translated-source-namestring`. Leave the two active-image splices, the recovery entry splice, and the `build-active` splice unchanged. Verify with a read-only count against `/var/cache/distfiles/autolith-0.67.2.tar.gz` (not the half-patched Portage tree): the two new needles match once, the two old needles match zero, and the other four still match once.

## 2. Land and prove the package

- [x] 2.1 Regenerate `metadata/md5-cache/dev-util/autolith-0.67.2` with `egencache --repo mndz --update dev-util/autolith` and verify its `_md5_` equals the MD5 of the edited ebuild. Commit that cache file and the ebuild only, with subject `dev-util/autolith: fix 0.67.2 recovery image splices`. Verify `git show --stat` lists those two paths and does not list `Manifest`.
- [x] 2.2 Hand the operator a fresh `emerge -av1 =dev-util/autolith-0.67.2` and do not invoke sudo or resume `/var/tmp/portage/dev-util/autolith-0.67.2-2026-10-26T22:37:47-07:00`. The task is done when that emerge finishes with both cores and both `manifest.sexp` files produced, and `timeout 5 autolith </dev/null` does not mention `/var/tmp/portage` or a missing fff helper. `autolith --version` may be run in addition; it is not the proof.
- [x] 2.3 Run `openspec validate fix-autolith-0672-image-entry --type change --strict` and verify it passes. No living spec and no Haskell change, so no `hk check` and no spec archive sync.

## Workflow follow-up

- Archive the change after the overlay commit and the emerge smoke are done.
