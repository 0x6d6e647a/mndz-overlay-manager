# Design

## Context

See `proposal.md` for why `0.58.0` and `0.60.0` fail. The installed package is `dev-util/autolith-0.57.0`. The live overlay ebuild is `autolith-0.60.0.ebuild`. `0.58.0` is pruned. The four files the ebuild splices (`src/startup/active-image.lisp`, `recovery/runtime.lisp`, `script/build-active.lisp`, `script/build-recovery.lisp`) are identical in the unpacked `0.58.0` and `0.60.0` trees.

`src_prepare` stamps `sbcl.version` (host `2.6.9`, upstream floor `2.6.6` on this tag) and then runs six exact-once string replaces. Against the unpacked `0.60.0` tree, needles 1 and 2 match zero times. Needles 3–6 match once. The replacer dies on needle 1, so compile never starts.

Autolith 0.57 saved the active image itself:

```
active-image-main                         ; probe or setenv + main
active-image--save-child
  save-lisp-and-die
    :toplevel #'active-image-main
```

Autolith 0.58+ delegates that to `sbcl-generations`:

```
image--toplevel                           ; probe, else host toplevel
  active-image--toplevel                  ; setenv + main
image-save
  funcall :prepare                        ; #'active-image--prepare-saver
  save-lisp-and-die
    :toplevel #'image--toplevel
```

`emerge` runs `script/build-active.lisp` with the core path, not `--child`. That calls `active-image-install`. On Linux, `image-install` forks and the child calls `image-save`. `active-image-save` runs only for the `--child` fresh-process saver.

Apply still copies this ebuild body and rewrites only `KEYWORDS`, the SBCL floor atom, and the deps `SRC_URI`. The body fix belongs in mndz-overlay.

## Goals / Non-Goals

**Goals:**

- `src_prepare` on `autolith-0.60.0` completes all six exact-once splices.
- `stash-dump-source-root` runs in the process `save-lisp-and-die` dumps, on the Linux fork path `emerge` uses.
- `relocate-to-live-source-root` runs on a real active-image launch, after the launcher source-root is known and before `main`. The generations probe does not relocate.
- Recovery entry, recovery save, `build-active` load, and `build-recovery` load splices stay byte-for-byte.

**Non-Goals:**

- Patching vendored `sbcl-generations` `image.lisp`, or adding a second stash inside `active-image-save`.
- Changing `script/gentoo-fhs.lisp`, the namestring hook, `qlot-00-fhs.lisp`, or the install keep-list.
- Fuzzy matching. A moved form must keep failing closed.

## Decisions

### 1. Edit `autolith-0.60.0.ebuild` in place

`0.60.0` failed in `src_prepare` before merge, same situation as the `0.50.2` image-entry fix. A `-r1` would publish a revision of a version that never installed. `0.58.0` stays pruned; one body fix covers both failed versions because their splice targets match.

- **Alternative — `-r1`:** rejected; nothing has installed `0.60.0`.
- **Alternative — restore `0.58.0` as well:** rejected; the overlay keeps one live ebuild.

### 2. Entry splice follows `active-image--toplevel`

Needle 1 today expects the `0.57` `cond` branch (13 spaces before `platform-setenv`). In `0.60` the same call is the only `platform-setenv` of `AUTOLITH_SOURCE_ROOT` in the file, at 8 spaces, inside `active-image--toplevel`:

```lisp
        (platform-setenv "AUTOLITH_SOURCE_ROOT" (namestring source-root))
        (restart-case
            (main (rest arguments))
```

Insert the existing `relocate-to-live-source-root` call between those two forms. `image--toplevel` handles `--autolith-internal-active-image-probe` and does not call this function, so the probe stays a pure identity check.

- **Alternative — splice `image--toplevel` in the deps tree:** rejected; the host function already has the source-root pathname, and the next deps bump would drop a vendored patch.

### 3. Stash splice follows `active-image--prepare-saver`

Needle 2 expects `active-image--save-child`'s `save-lisp-and-die` with `:toplevel #'active-image-main`. That function is gone. `image-save` calls `:prepare` and then saves. Both savers pass `#'active-image--prepare-saver`:

- Fork (emerge): `active-image-install` → `image--fork-save` → `image-save`.
- Fresh process: `build-active.lisp --child` → `active-image-save` → `image-save`.

Replace the save-lisp needle with an exact-once insert of the existing no-argument stash as the first body form of `active-image--prepare-saver`, before the `setf` that clears session state. `stash-dump-source-root` still prefers `AUTOLITH_DUMP_SOURCE_ROOT`, which `src_compile` exports as `${S}` before SBCL starts. The special is in the dumped image; the full GC inside `image-save` does not drop it.

`script/build-active.lisp` already loads `script/gentoo-fhs.lisp` (needle 5, still a unique match) before `asdf:load-system` and before either saver. The fork child inherits that package.

- **Alternative — splice only `active-image-save`:** rejected; emerge never calls it.
- **Alternative — splice both `active-image-save` and `prepare-saver`:** rejected; `prepare` already covers both paths, and a second call is a second needle to rot.

### 4. Leave needles 3–6 alone

Counted once each on the unpacked `0.60.0` tree:

| Needle | File | Still matches |
| --- | --- | --- |
| Recovery entry, skip relocate on `--probe` | `recovery/runtime.lisp` | yes |
| Stash before recovery `save-lisp-and-die` / `#'recovery-main` | `recovery/runtime.lisp` | yes |
| Load `gentoo-fhs.lisp` before `build-sandbox.lisp` | `script/build-active.lisp` | yes |
| Load `gentoo-fhs.lisp` inside recovery's Quicklisp setup | `script/build-recovery.lisp` | yes |

`image-install` still writes `manifest.sexp` beside the core (`merge-pathnames` of that name onto the core pathname). The ebuild's post-build checks stay valid. `active-image-source-paths` still names the same extra files the ebuild keeps (`bin/autolith*`, `script/build-active*`, `script/restart-publisher.lisp`, `autolith.asd`, `qlfile`, `qlfile.lock`, `sbcl.version`) plus `src/` Lisp, which `cp -a src` installs.

## Risks / Trade-offs

- **[Risk]** `src_compile` has not been run. A later core build can still fail on new `0.60` Lisp. → **Mitigation:** emerge of `=dev-util/autolith-0.60.0` is the gate. Preparing cleanly is not done.
- **[Risk]** The next tag indents or renames these forms again and `src_prepare` dies the same way. → **Mitigation:** keep exact-once. The failure stays early and names the file. Do not fuzzy-match.
- **[Risk]** `gentoo-fhs` is missing in the saved process, so `symbol-call` errors inside `prepare` and `image-save` exits 1. → **Mitigation:** needle 5 still loads it in the parent before the fork, and the `--child` script loads it before `active-image-save`.
- **[Risk]** A hashed input is deleted before `git commit` and the image probe reports changed inputs. → **Mitigation:** the explicit path list matches `0.57`, and the ebuild still deletes only trees outside that list (`tests/`, `nix/`, `server/`, human-only `docs/`). New `src/` files are kept.

## Migration Plan

1. In mndz-overlay, edit `dev-util/autolith/autolith-0.60.0.ebuild` per decisions 2 and 3. Do not touch `Manifest` `DIST` lines (`thin-manifests`).
2. Regenerate `metadata/md5-cache/dev-util/autolith-0.60.0` so `_md5_` is the MD5 of the edited ebuild. A body edit invalidates the checked-in cache; `gencache` without `--force` hard-fails on that mismatch.
3. Commit the ebuild and that cache file together. Subject shape: `dev-util/autolith: fix 0.60.0 image entry splice`.
4. Operator: `emerge -av1 =dev-util/autolith-0.60.0`, then `timeout 5 autolith </dev/null`. Pass requires no `/var/tmp/portage` path and no missing fff helper. `autolith --version` is extra, not the proof.
5. Rollback is reverting that overlay commit. `0.57.0` stays installed until `0.60.0` emerges.

The manager change is these planning artifacts only. The next `update autolith` copies the repaired body.
