# Design

## Context

See `proposal.md` for why `0.67.2` fails. The installed package is `dev-util/autolith-0.66.0`. The live overlay ebuild is `autolith-0.67.2.ebuild`. Apply copied that body from `0.66.0` and rewrote only `KEYWORDS`, the SBCL floor atom, and the deps `SRC_URI`.

`src_prepare` stamps `sbcl.version` (host `2.6.9`, upstream floor `2.6.6` on this tag) and then runs six exact-once string replaces. Against the unpacked `0.67.2` tarball:

| # | File | Result |
| --- | --- | --- |
| 1 | `src/startup/active-image.lisp` entry | matches once |
| 2 | `src/startup/active-image.lisp` prepare-saver | matches once |
| 3 | `recovery/runtime.lisp` entry | matches once |
| 4 | `recovery/runtime.lisp` save | matches zero |
| 5 | `script/build-active.lisp` | matches once |
| 6 | `script/build-recovery.lisp` | matches zero |

The replacer dies on needle 4, so needle 6 is never attempted. The failed Portage tree `autolith-0.67.2-2026-10-26T22:37:47-07:00` already contains splices 1–3. A proof emerge unpacks a fresh tree.

Autolith 0.66 saved the recovery image with a single space after `:toplevel`, and it loaded Quicklisp inside `load-recovery-source`. Autolith 0.67 keeps the same save call and the same child function, with two text moves:

```
0.66 recovery-image-save          0.67 recovery-image-save
  :toplevel #'recovery-main         :toplevel    #'recovery-main
                                    :executable  nil
                                    :purify      t
                                    :compression nil

0.66 build-recovery                0.67 build-recovery
  labels load-recovery-source       load quicklisp-setup
    load quicklisp-setup            quickload :sbcl-generations
    quickload :serapeum              labels load-recovery-source
    quickload :sbcl-generations        quickload :serapeum
    export RECOVERY-*                  export RECOVERY-*
    load recovery/runtime.lisp         load recovery/runtime.lisp
```

`load-recovery-source` still runs only on the `--child` path, and that path is still the only load of `recovery/runtime.lisp`. The parent now loads Quicklisp and `sbcl-generations` before `labels`, in both the parent and the child script.

## Goals / Non-Goals

**Goals:**

- `src_prepare` on `autolith-0.67.2` completes all six exact-once splices.
- `stash-dump-source-root` still runs in `recovery-image-save` immediately before `save-lisp-and-die`.
- The recovery child still loads `script/gentoo-fhs.lisp`, installs the compile-namestring hook, and compiles `recovery/runtime.lisp` under `call-with-translated-source-namestring`.
- Active-image entry, active-image stash, recovery entry, and `build-active` load splices stay byte-for-byte.

**Non-Goals:**

- Folding whitespace or matching with a regex. A moved form must keep failing closed.
- Loading `gentoo-fhs.lisp` in the recovery parent, or quickloading `sbcl-generations` a second time inside `load-recovery-source`.
- Changing `script/gentoo-fhs.lisp`, the namestring hook, or the install keep-list.

## Decisions

### 1. Edit `autolith-0.67.2.ebuild` in place

`0.67.2` failed in `src_prepare` before merge, same situation as the `0.50.2` and `0.60.0` image-entry fixes. A `-r1` would publish a revision of a version that never installed.

- **Alternative — `-r1`:** rejected; nothing has installed `0.67.2`.
- **Alternative — fix this in the manager rewriter:** rejected; apply does not own the splice body, and the next bump copies the overlay ebuild.

### 2. Save splice keeps the same three lines and the new column gap

Needle 4 is the only save form in `recovery/runtime.lisp`. The surrounding two lines are unchanged. The third line in the tarball is `:toplevel` followed by four spaces, then `#'recovery-main`. Update both the search text and the replacement text to that gap, and keep the existing stash call on the line before `save-lisp-and-die`. Do not extend the needle to `:executable`, `:purify`, or `:compression`; those lines are outside the current match.

The recovery entry needle ends at `(if (equal (rest arguments) '("--probe"))`. The plist alignment that follows it (`:sbcl-version`, `:operating-system`) is outside that needle, and the needle still matches once. Leave it.

- **Alternative — drop `:toplevel` from the needle:** rejected; a shorter needle can match a different `save-lisp-and-die` if one appears later.

### 3. Recovery build splice follows the inner `load-recovery-source` block

Needle 6's full text, starting at the 13-space `(load quicklisp-setup)` plus both quickloads, occurs zero times. This block still occurs once, at the same 13-space indent, inside `load-recovery-source`:

```lisp
             (uiop:symbol-call '#:ql '#:quickload :serapeum :silent t)
             (let ((package (or (find-package "AUTOLITH")
                                (make-package "AUTOLITH" :use '("CL")))))
               (export (mapcar (lambda (name) (intern name package))
                               '("RECOVERY-MAIN" "RECOVERY-IMAGE-SAVE"))
                       package))
             (load (merge-pathnames "recovery/runtime.lisp" source-root)))
```

Replace that block with the same package export, preceded by the existing `gentoo-fhs.lisp` load and `install-compile-namestring-hook` call, and with the runtime load wrapped in the existing `call-with-translated-source-namestring`. Do not include `(load quicklisp-setup)` or the `sbcl-generations` quickload in the new needle. The child script already ran both before it called `load-recovery-source`.

- **Alternative — splice the parent Quicklisp load:** rejected; that load runs in the parent, which never compiles `recovery/runtime.lisp`, and the hook would not wrap the child load.
- **Alternative — keep quickloading `sbcl-generations` inside the function:** rejected; 0.67 already loaded it, and the old needle's second quickload is what made the match fail.

### 4. Leave needles 1, 2, 3, and 5 alone

Counted once each on the unpacked `0.67.2` tarball. Their replacement text stays as copied from `0.66.0`.

## Risks / Trade-offs

- **[Risk]** `src_compile` has not been run. A later core build can still fail on new `0.67` Lisp. → **Mitigation:** a fresh emerge of `=dev-util/autolith-0.67.2` is the gate. A clean `src_prepare` is not done.
- **[Risk]** The next tag realigns `:toplevel` or moves `load-recovery-source` again. → **Mitigation:** keep exact-once. The failure stays in `src_prepare` and names the file.
- **[Risk]** Resuming the half-patched Portage tree applies needles 1–3 a second time and dies with `expected exactly 1 match, got 0` on an already-spliced file. → **Mitigation:** the proof emerge unpacks again. Do not `ebuild resume` that tree.
- **[Risk]** The hook is absent when the child compiles `recovery/runtime.lisp`. → **Mitigation:** the new needle loads `gentoo-fhs.lisp` inside `load-recovery-source`, which is the child path, before that load.

## Migration Plan

1. In mndz-overlay, edit `dev-util/autolith/autolith-0.67.2.ebuild` per decisions 2 and 3. Do not touch `Manifest` `DIST` lines (`thin-manifests`).
2. Regenerate `metadata/md5-cache/dev-util/autolith-0.67.2` with `egencache --repo mndz --update dev-util/autolith` so `_md5_` is the MD5 of the edited ebuild. A body edit invalidates the checked-in cache.
3. Commit the ebuild and that cache file together. Subject: `dev-util/autolith: fix 0.67.2 recovery image splices`.
4. Operator, not this change: `emerge -av1 =dev-util/autolith-0.67.2`, then `timeout 5 autolith </dev/null`. Pass requires no `/var/tmp/portage` path and no missing fff helper. `autolith --version` is extra, not the proof.
5. Rollback is reverting that overlay commit. `0.66.0` stays installed until `0.67.2` emerges.

The manager change is these planning artifacts only. The next `update autolith` copies the repaired body.
