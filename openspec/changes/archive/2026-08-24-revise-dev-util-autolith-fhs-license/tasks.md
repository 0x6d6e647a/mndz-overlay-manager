## 1. Overlay `-r1` (LICENSE only)

- [x] 1.1 Confirm the live Autolith PV (currently 0.32.2). If it has moved, apply `-rN` on that PV, not a resurrected 0.32.2
- [x] 1.2 Add overlay `licenses/COLL-Attribution` (plaintext of the COLL LICENSE.lisp legal terms and `*license*` plist; do not map to MIT)
- [x] 1.3 Replace `autolith-<PV>.ebuild` with `autolith-<PV>-r1.ebuild`: inventoried `LICENSE` / `LICENSE+` and per-project comment from design.md; layout, wrapper, `src_compile`, KEYWORDS, SBCL atom, and `SRC_URI` unchanged
- [x] 1.4 Run `ebuild … manifest` and package `egencache`; overlay commit 1 (delete the unrevised filename)

## 2. Overlay `-r2` (FHS split)

- [x] 2.1 Replace `autolith-<PV>-r1.ebuild` with `autolith-<PV>-r2.ebuild`: `src_install` two dests (`/usr/share/autolith` vs `/usr/$(get_libdir)/autolith`); synthetic `sbcl-source` under share; wrapper two dests; `GIT_CONFIG_VALUE_0` = share; no `common-lisp-3`; `src_compile` unchanged; LICENSE already correct
- [x] 2.2 Run `ebuild … manifest` and package `egencache`; overlay commit 2 (delete the `-r1` filename; working tree has only `-r2`)

## 3. Operator smoke

- [x] 3.1 Emerge `=dev-util/autolith-<PV>-r2` (full rebuild; do not treat Manifest-only as smoke)
- [x] 3.2 Run `autolith --version` from `PATH` successfully
- [x] 3.3 Confirm share has `bin/autolith` and `.qlot/`; libdir has `lib/libfff_c.so` and cores; `/usr/bin/autolith` is the wrapper

## 4. Manager OpenSpec gate

- [x] 4.1 Update Purpose in living `openspec/specs/dev-util-autolith-seed/spec.md` to mention LICENSE inventory and two dests (deltas do not replace Purpose)
- [x] 4.2 `openspec validate revise-dev-util-autolith-fhs-license --strict --type change`
- [x] 4.3 `hk check` on mndz-overlay-manager (planning artifacts only; no Haskell)
