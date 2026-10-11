# Proposal

## Why

`dev-util/autolith-0.58.0` and `dev-util/autolith-0.60.0` die in `src_prepare` because the ebuild still splices the Autolith 0.57 active-image forms. Upstream 0.58 moved the probe and `save-lisp-and-die` into `sbcl-generations`, so the exact-once replacer finds zero matches and never reaches compile. The installed package is still `0.57.0`. The live ebuild is `0.60.0`, and that version never merged.

## What Changes

- Retarget the active-image **entry** splice in `autolith-0.60.0.ebuild` onto `active-image--toplevel`, and keep the same `relocate-to-live-source-root` call before `main`.
- Move the active-image **stash** splice onto `active-image--prepare-saver`. That is the function `sbcl-generations:image-save` runs immediately before `save-lisp-and-die`, including the Linux fork path `emerge` actually takes.
- Leave the four recovery and build-script splices unchanged. They still match the unpacked `0.60.0` tree once each.
- Edit the live `autolith-0.60.0.ebuild` in place. `0.60.0` never installed, so this is not a `-r1`. Do not revive the pruned `0.58.0` ebuild.

## Non-goals

- No revision bump, no resurrecting `0.58.0`, and no new Autolith PV.
- No manager Haskell, no new apply rewrite fields, and no deps-tarball republish.
- No KEYWORDS, SBCL floor, LICENSE, FHS dest, or install-set changes.
- No loosening of the exact-once string match into a fuzzy or regex splice.
- No Autolith upstream patch in this change.
- No living-spec delta. `dev-util-autolith-seed` already requires dumped cores to relocate Lisp paths onto the launcher share dest.

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- (none — `dev-util-autolith-seed` already requires image entry to translate dump-time source-root onto the launcher source-root, and session start must not use `/var/tmp/portage`. This change restores the splice anchors so `0.60.0` meets that requirement. `skip_specs: true`.)

## Impact

- **mndz-overlay:** `dev-util/autolith/autolith-0.60.0.ebuild` and the matching `metadata/md5-cache/dev-util/autolith-0.60.0` (`_md5_` follows the ebuild bytes). `thin-manifests` leaves `Manifest` `DIST` lines unchanged. One overlay commit of those two files.
- **mndz-overlay-assets:** none.
- **mndz-overlay-manager:** planning artifacts only. No Haskell. The next `update autolith` copies this ebuild body and still rewrites only `KEYWORDS`, the SBCL floor atom, and the deps `SRC_URI`.
- **Operator:** `emerge =dev-util/autolith-0.60.0`, then a session start (`timeout 5 autolith </dev/null`) that does not mention `/var/tmp/portage` or a missing fff helper. `--version` alone is not proof.
