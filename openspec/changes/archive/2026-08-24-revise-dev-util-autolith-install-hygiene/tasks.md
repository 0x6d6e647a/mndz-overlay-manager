## 1. Overlay `-r3` (install set)

- [x] 1.1 Confirm the live Autolith PV (currently `0.32.2-r2`). If PV has moved, apply `-rN` on that live atom, not a resurrected 0.32.2
- [x] 1.2 Replace `autolith-<PV>-r2.ebuild` with `autolith-<PV>-r3.ebuild`: prune tracked junk **before** `git add`; fabricate git; `gc --prune=now`; drop sample hooks; `rm .git/index` + `git read-tree HEAD`
- [x] 1.3 Stop `cp -a "${S}/."`; install the keep list (Lisp, pruned `.qlot`, packed `.git`, wrapper launchers, recovery/image scripts, `sbcl-source-releases.sha256`, synthetic `sbcl-source`)
- [x] 1.4 Omit `.github/`, flakes/`nix/`, `server/`, `bin/autolith-release`, `script/install`, bootstrap/`qlot-install.lisp`/`build-fff*`, `sbcl-source.sha256`, `native/fff/`, `tests/`, packaged `AGENTS.md`/`AUTOLITH.org`, 0.32.2 human-only `docs/` (do not `rm -rf docs`)
- [x] 1.5 After `libcolorlisp-tree-sitter.so` exists, strip ColorLisp `vendor/grammars`, `vendor/tree-sitter`, `vendor/common`, and `native/colorlisp-tree-sitter.c` from the install; keep `languages/` and ColorLisp Lisp
- [x] 1.6 Strip agreed `.qlot` leaves (tmp, sandbox `build/` helper, bordeaux-threads `docs/`, ironclad `testing/`, cffi `doc/`/`tests`/`examples`, nested `.github/`); keep local-time `zoneinfo/` and ironclad `doc/`
- [x] 1.7 Do **not** rewrite qlot confs in the ebuild; do **not** change LICENSE, KEYWORDS, SBCL atom, `SRC_URI`, or dests
- [x] 1.8 Run `ebuild … manifest` and package `egencache`; overlay commit (delete the `-r2` filename; working tree has only `-r3`)

## 2. Operator smoke

- [x] 2.1 Emerge `=dev-util/autolith-<PV>-r3` (full rebuild; do not treat Manifest-only as smoke)
- [x] 2.2 Run `autolith --version` from `PATH` successfully
- [x] 2.3 Confirm share omits `tests/`, `server/`, `flake.nix`, ColorLisp `vendor/grammars`; libdir still has `libcolorlisp-tree-sitter.so` and cores; `.git` exists and is not dirty for tracked files (with `safe.directory`)

## 3. Manager Sbcl materialize

- [x] 3.1 Replace operator-home → `/home/builder` sanitizer: after `qlot install`, drop `:qlot-source-directory` / `:setup-file` / builder `:directory`; keep also-exclude; hard-fail if `/home/` remains in those confs
- [x] 3.2 Strip unused `fff/` trees (`plugin/`, `lua/`, `tests/`, `.github/`, flakes, node `packages/`) while keeping cargo workspace members + `vendor/` + `.cargo/`; hard-fail if `cargo build --offline --locked -p fff-c` cannot run on the staged tree
- [x] 3.3 Update tests for conf emit (no `/home/`, no dropped keys) and fff pack membership
- [x] 3.4 Do **not** republish `autolith-0.32.2-deps.tar.xz`

## 4. Specs and gate

- [x] 4.1 Update Purpose in living `openspec/specs/dev-util-autolith-seed/spec.md` to mention the pruned install set (deltas do not replace Purpose)
- [x] 4.2 `openspec validate revise-dev-util-autolith-install-hygiene --strict --type change`
- [x] 4.3 `hk check` on mndz-overlay-manager
