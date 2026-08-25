## 1. Overlay `-r4` (relocatable runtime)

- [x] 1.1 Confirm the live Autolith PV (currently `0.32.2-r3`). If PV has moved, apply `-rN` on that live atom, not a resurrected 0.32.2
- [x] 1.2 Replace `autolith-<PV>-r3.ebuild` with `autolith-<PV>-r4.ebuild`: in `src_prepare` (before git fabricate) patch active and recovery image entry to stash dump-root and, when live source-root differs, `asdf:load-asd` translated systems, clear/reinit output-translations, set Quicklisp home to `<source-root>/.qlot/`, set `*local-project-directories*` to XDG cache `autolith/qlot-local-projects/`. Do not hardcode `/usr/share/autolith`; do not rewrite SBCL contrib paths
- [x] 1.3 Bind compile-time `sb-c:*source-namestring*` (ASDF around-compile or equivalent) so files under `${S}` record namestrings under `${EPREFIX}/usr/share/autolith`, not libdir
- [x] 1.4 After `.qlot` is copied in `src_compile`, install `.qlot/local-init/qlot-00-fhs.lisp` that only retargets `*local-project-directories*` to the same XDG cache path (sorts before `qlot-10-https.lisp`)
- [x] 1.5 Do **not** rewrite qlot confs in the ebuild; do **not** chmod share or `touch` share `system-index.txt`; do **not** change LICENSE, KEYWORDS, SBCL atom, `SRC_URI`, dests, or the pruned install set
- [x] 1.6 Run `ebuild … manifest` and package `egencache`; overlay commit (delete the `-r3` filename; working tree has only `-r4`)

## 2. Operator smoke

- [x] 2.1 Emerge `=dev-util/autolith-<PV>-r4` (full rebuild; do not treat Manifest-only as smoke)
- [x] 2.2 Run `autolith --version` from `PATH` successfully
- [x] 2.3 Run `timeout 5 autolith </dev/null`: output MUST NOT mention `/var/tmp/portage` or a missing fff helper. A TTY/timeout exit after that is a pass for this bug. Operator may also `autolith auth grok`. Do not treat `--from-source` as a `-r4` gate

## 3. Specs and gate

- [x] 3.1 Update Purpose in living `openspec/specs/dev-util-autolith-seed/spec.md` to mention relocatable dumped cores (share Lisp dest, XDG Quicklisp index; deltas do not replace Purpose)
- [x] 3.2 `openspec validate revise-dev-util-autolith-relocatable-runtime --strict --type change`
- [x] 3.3 `hk check` on mndz-overlay-manager
