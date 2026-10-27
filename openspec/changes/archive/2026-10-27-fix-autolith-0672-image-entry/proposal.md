# Proposal

## Why

`dev-util/autolith-0.67.2` dies in `src_prepare`. The ebuild body copied from `0.66.0` still splices `recovery-image-save` with one space after `:toplevel`, and it still expects `script/build-recovery.lisp` to load Quicklisp inside `load-recovery-source`. Upstream 0.67 aligned that keyword column and moved the Quicklisp load out of that function, so the exact-once replacer finds zero matches and never reaches compile. The installed package is still `0.66.0`. `0.67.2` never merged.

## What Changes

- Retarget the `recovery/runtime.lisp` save splice so `:toplevel` matches the 0.67.2 column alignment (`:toplevel` followed by four spaces, then `#'recovery-main`). Keep the same `stash-dump-source-root` call immediately before `save-lisp-and-die`.
- Retarget the `script/build-recovery.lisp` splice onto the inner `load-recovery-source` block that still quickloads serapeum, exports `RECOVERY-MAIN` and `RECOVERY-IMAGE-SAVE`, and loads `recovery/runtime.lisp`. Load `script/gentoo-fhs.lisp` and install the compile-namestring hook there, and wrap that runtime load with `call-with-translated-source-namestring`. Leave the parent `(load quicklisp-setup)` and the `sbcl-generations` quickload outside that function.
- Leave the two `active-image.lisp` splices, the `recovery-run` entry splice, and the `script/build-active.lisp` splice unchanged. Each still matches the unpacked `0.67.2` tree once.
- Edit the live `autolith-0.67.2.ebuild` in place. `0.67.2` never installed, so this is not a `-r1`.

## Non-goals

- No revision bump, no new Autolith PV, and no resurrecting pruned ebuilds.
- No manager Haskell, no new apply rewrite fields, and no deps-tarball republish.
- No KEYWORDS, SBCL floor, LICENSE, FHS dest, or install-set changes.
- No loosening of the exact-once string match into a fuzzy or regex splice.
- No Autolith upstream patch in this change.
- No living-spec delta. `dev-util-autolith-seed` already requires dumped cores to relocate Lisp paths onto the launcher share dest.
- Do not resume the failed Portage tree `autolith-0.67.2-2026-10-26T22:37:47-07:00`. `src_prepare` already wrote the three earlier splices there.

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- (none — `dev-util-autolith-seed` already requires image entry to translate dump-time source-root onto the launcher source-root, and session start must not use `/var/tmp/portage`. This change restores the two drifted splice anchors so `0.67.2` meets that requirement. `skip_specs: true`.)

## Impact

- **mndz-overlay:** `dev-util/autolith/autolith-0.67.2.ebuild` and the matching `metadata/md5-cache/dev-util/autolith-0.67.2` (`_md5_` follows the ebuild bytes). `thin-manifests` leaves `Manifest` `DIST` lines unchanged. One overlay commit of those two files.
- **mndz-overlay-assets:** none.
- **mndz-overlay-manager:** planning artifacts only. No Haskell. The next `update autolith` copies this ebuild body and still rewrites only `KEYWORDS`, the SBCL floor atom, and the deps `SRC_URI`.
- **Operator:** a fresh `emerge =dev-util/autolith-0.67.2`, then a session start (`timeout 5 autolith </dev/null`) that does not mention `/var/tmp/portage` or a missing fff helper. `--version` alone is not proof. The operator runs emerge; this change does not invoke sudo.
