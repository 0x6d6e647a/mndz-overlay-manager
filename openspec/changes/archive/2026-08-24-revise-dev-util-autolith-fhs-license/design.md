## Context

See `proposal.md` for motivation. Live overlay atom at proposal time is `dev-util/autolith-0.32.2` (`autolith-0.32.2.ebuild`, no `-rN`), `LICENSE="ISC"`, single prefix `/usr/$(get_libdir)/autolith` plus `/usr/bin/autolith`. Seed identity in `dev-util-autolith-seed` remains v0.17.2; apply already preserves template body (install, wrapper, stamp, cores) and rewrites only KEYWORDS, SBCL floor atom, and deps `SRC_URI`.

Inventory sources (do not `qlot install` current Autolith master — that lock is v0.40.0+):

- Emerged 0.32.2 tree `/usr/lib64/autolith/.qlot` (80 software projects, 0 FASLs)
- Autolith and `native/fff/LICENSE` (ISC, MIT)
- Deps tarball `fff/` at pin `e2cad2f` (fff 0.10.3); `cargo build -p fff-c` only

OpenSpec lives only in mndz-overlay-manager (overlay has no `openspec/` by policy). Implementation files land in mndz-overlay. No manager Haskell.

## Goals / Non-Goals

**Goals:**

- Two overlay commits on the live Autolith PV: LICENSE `-r1`, then FHS split `-r2`.
- Overlay `licenses/COLL-Attribution`.
- Seed-spec delta so later apply copies the two-dest + inventory body.
- Operator smoke on `-r2` only.

**Non-Goals:**

- Manager rewrite fields, image recipe, KEYWORDS, SBCL floor, deps tarball republish.
- Nested C licenses inside `libgit2-sys` / `libz-sys` beyond crate SPDX.
- Moving the whole tree to `/usr/share` or inheriting `common-lisp-3`.

## Decisions

### 1. Live PV and two filenames

- Apply `-rN` on whatever Autolith PV is live. At proposal time that is `0.32.2`.
- Commit 1: replace `autolith-<PV>.ebuild` with `autolith-<PV>-r1.ebuild` (LICENSE + `COLL-Attribution` file). Manifest / egencache.
- Commit 2: replace `-r1` with `autolith-<PV>-r2.ebuild` (FHS). Manifest / egencache.
- Working tree after commit 2 has only `-r2` so exact-set prune still sees one live ebuild per PV. `-r1` exists in git as commit 1.
- **Alternative — squash into one `-rN`:** rejected unless the operator drops two-step history.
- **Alternative — keep unrevised filename beside `-r1`:** extra live atom; Portage prefers `-r1` anyway.

### 2. LICENSE tokens (`-r1`)

Exact field (unique Gentoo / overlay tokens, alphabetical in `LICENSE+`):

```
LICENSE="ISC"
# Autolith ISC; fff MIT; fff-c crate SPDX; .qlot + colorlisp vendor (see comment).
LICENSE+="
	Apache-2.0 Apache-2.0-with-LLVM-exceptions BSD BSD-2 Boost-1.0
	CC0-1.0 COLL-Attribution ISC LLGPL-2.1 MIT MIT-0 MPL-2.0
	Unicode-3.0 Unlicense WTFPL-2 ZLIB icu public-domain
"
```

fff-c: unique SPDX from `cargo tree -p fff-c` on the 0.32.2 deps tarball (113 crates). New vs Lisp-only: `Apache-2.0`, `Apache-2.0-with-LLVM-exceptions`, `Boost-1.0`, `MIT-0`, `MPL-2.0`, `Unicode-3.0`. Same bar as overlay `mise` / `usage` `LICENSE+=`.

Do not list 113 crate names in the comment. Do name every `.qlot` software project (and Autolith / fff) in the comment.

**`.qlot` project → token** (0.32.2 emerged tree):

| Token | Projects |
|---|---|
| ISC | autolith, cl-colorist, cl-exec-sandbox, clifff, clinedi, colorlisp, mcparen, sbcl-workers, sexp-store |
| COLL-Attribution | cl-jobpond, colordiff, idsmall, parenchek, sbcl-generations, sexp-config |
| MIT | bordeaux-threads, cffi, closer-mop, dexador, serapeum, 3bz, babel, cl+ssl, cl-tga, deflate, fast-http, fast-io, global-vars, idna, iterate, parse-declarations, pngload, split-sequence, static-vectors, swap-bytes, trivial-features, trivial-file-size, trivial-gray-streams, uiop, usocket, fff, `.qlot/asdf.lisp`, Quicklisp client, colorlisp grammars + tree-sitter core (except clojure CC0), bordeaux-threads docs theme |
| BSD | cl-base64, ironclad, opticl, chipz, chunga, cl-jpeg, cl-ppcre, ieee-floats, local-time, monkeylib-binary-data, nibbles, opticl-core, parse-number, retrospectiff, salza2, skippy, smart-buffer, string-case, yason, zpb-exif, zpng, iterate/ext/fiveam |
| BSD-2 | cl-cookie, flexi-streams, proc-parse, quri, xsubseq |
| public-domain | alexandria, cl-utilities, parse-float, trivial-garbage, iterate/ext/alexandria |
| ZLIB | documentation-utils, mmap, pathname-utils, trivial-indent, trivial-mimes |
| LLGPL-2.1 | lisp-namespace, trivia, trivial-cltl2, type-i |
| Unlicense | trivial-macroexpand-all |
| WTFPL-2 | introspect-environment (`:license "WTFPL"`) |
| icu | colorlisp `vendor/tree-sitter/src/unicode` |
| CC0-1.0 | colorlisp clojure grammar |

**Alternative — qlot-install Autolith master:** wrong lock (v0.40.0 extras). **Alternative — crate comment for all 113 fff-c deps:** Portage only enforces unique tokens.

### 3. Overlay `licenses/COLL-Attribution`

Six Lambda Symbolics projects use the same COLL plist (`use copy modify distribute sell sublicense` + `retain-notice`). Gentoo has no token. Precedent: overlay `licenses/FSL-1.1-MIT` for crush. No `profiles/license_groups` (this overlay has none). File is plaintext of `LICENSE.lisp` legal terms plus the authoritative `*license*` value. Do not map COLL to MIT.

### 4. FHS split (`-r2`); `src_compile` unchanged

```
/usr/share/autolith/                 Lisp, .qlot, .git, scripts, bin/autolith, sbcl-source
/usr/$(get_libdir)/autolith/         lib/*.so, libexec/helper, cores/{recovery,active}
/usr/bin/autolith                    wrapper (two dests)
```

- `src_install`: `cp -a "${S}/."` to share (not libdir); natives/helper/cores into libdir; synthetic `sbcl-source` under share (`version.lisp-expr` + `src` → `/usr/$(get_libdir)/sbcl/src`).
- Wrapper: `share=` and `lib=`; `GIT_CONFIG_VALUE_0` = share; `exec bash "${share}/bin/autolith"`.
- Upstream `bin/autolith` sets `source_root` to parent of `bin/`. Cores/natives already read `AUTOLITH_*` / `COLORLISP_*` / `CL_EXEC_SANDBOX_HELPER`. Direct share launcher without the wrapper misses cores and natives — accepted; PATH stays `/usr/bin/autolith`.
- `get_libdir` everywhere for the arch-specific half; never hard-code `lib64`.
- **Alternative — whole tree in share:** ELF and SBCL cores are not FHS `/usr/share`. **Alternative — `common-lisp-3`:** private app, not a library on every SBCL sysinit path.

Natives/cores **keep** libdir paths. What moves: sources, `.git`, launcher, `sbcl-source`.

### 5. Manager / specs

- Delta `dev-util-autolith-seed` only. Do not expand apply rewrite fields.
- Leave seed PV 0.17.2 and KEYWORDS requirement as archaeology (live KEYWORDS already include `~sparc ~x64-macos` from apply).
- Update living spec **Purpose** (deltas do not replace Purpose) when applying this change’s spec work.
- Overlay has no OpenSpec tree.

### 6. Smoke and rebuild

- Do not emerge `-r1` solely to install a LICENSE string (would rebuild cores).
- Smoke: `emerge =dev-util/autolith-<PV>-r2` then `autolith --version`. `-r2` recompiles natives and both cores.

## Risks / Trade-offs

- **[Risk]** Operator env still points at old `AUTOLITH_SBCL_SOURCE_ROOT` or git `safe.directory` under libdir → **Mitigation:** document; default wrapper is enough after emerge; natives/cores paths unchanged.
- **[Risk]** Direct `/usr/share/autolith/bin/autolith` without wrapper → **Mitigation:** accepted; package entrypoint is `/usr/bin/autolith`.
- **[Risk]** Future Autolith PV adds a `.qlot` license not in this inventory → **Mitigation:** apply copies template LICENSE; another `-rN` if a new token appears.
- **[Risk]** `COLL-Attribution` not in `@FREE` → **Mitigation:** same as overlay `FSL-1.1-MIT`; no license_groups in this overlay.
- **[Risk]** `-r2` emerge is long → **Mitigation:** expected; smoke is not `ebuild manifest` alone.

## Migration Plan

1. Overlay commit 1: `licenses/COLL-Attribution`, `autolith-<PV>-r1.ebuild`, Manifest, package cache. Delete unrevised filename.
2. Overlay commit 2: `autolith-<PV>-r2.ebuild`, Manifest, package cache. Delete `-r1` filename.
3. Operator: `emerge -av1 =dev-util/autolith-<PV>-r2` then `autolith --version`.
4. Manager: seed-spec delta + Purpose line; `openspec validate` / `hk check`. No Haskell.
5. Archive when smoke and gates are green.

## Open Questions

(none)
