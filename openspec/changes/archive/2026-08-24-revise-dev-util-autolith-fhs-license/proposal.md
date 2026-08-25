## Why

Overlay `dev-util/autolith` still declares `LICENSE="ISC"` while `src_install` ships Autolith, `.qlot/` third-party Lisp, fff, and colorlisp vendor trees. The same install dumps ELF, an SBCL helper, and cores into `/usr/$(get_libdir)/autolith` together with arch-independent Lisp sources. Qlot’s `/usr/share` layout is the wrong copy: Autolith is not “just Lisp.” Two overlay revisions on the live PV separate the license inventory from the FHS split so a token mistake is not mixed with a path rewrite.

## What Changes

- On the **live** Autolith PV (currently `0.32.2`; if PV has moved, apply `-rN` on that live atom, not a resurrected 0.32.2):
  - Overlay commit 1: replace `autolith-<PV>.ebuild` with `autolith-<PV>-r1.ebuild`. **LICENSE only.** Inventory tokens for Autolith, every installed `.qlot` project, colorlisp vendor, and fff-c crate SPDX. Add overlay `licenses/COLL-Attribution`. Layout unchanged.
  - Overlay commit 2: replace `-r1` with `autolith-<PV>-r2.ebuild`. **FHS split.** Arch-independent tree under `/usr/share/autolith`; ELF, helper, and cores under `/usr/$(get_libdir)/autolith`; `/usr/bin/autolith` wrapper uses two dests. LICENSE already correct.
- After commit 2 the working tree has only `-r2` (one live ebuild per Autolith PV). `-r1` exists in git as commit 1.
- **BREAKING** for anyone invoking `/usr/$(get_libdir)/autolith/bin/autolith` or pinning `AUTOLITH_SBCL_SOURCE_ROOT` / git `safe.directory` at the old single prefix. Natives and cores stay at libdir paths. Default wrapper is enough for a normal emerge.
- Delta `dev-util-autolith-seed`: LICENSE is an inventory, not Autolith-only ISC; private prefix is two dests plus the wrapper. Seed identity remains v0.17.2 archaeology. Manager apply still only rewrites KEYWORDS, SBCL floor atom, and deps `SRC_URI`.
- Operator smoke: emerge `=dev-util/autolith-<PV>-r2` and `autolith --version`. Do not emerge `-r1` solely for LICENSE.

## Non-goals

- No mndz-overlay-manager Haskell, image recipe, generator bump, or extra apply rewrite fields.
- No mixing into `seed-dev-lisp-qlot` / `materialize-overlay-qlot` (already done).
- No qlot/Quicklisp as Autolith `RDEPEND`/`BDEPEND`.
- No `common-lisp-3`; do not move the whole tree to `/usr/share`.
- No KEYWORDS / SBCL floor / deps-tarball / `sbcl.version` changes.
- No compiling Autolith against system qlot; no nyxt-style single binary; no host-path materialize fallback.
- Nested C third-party files inside `libgit2-sys` / `libz-sys` (Info-ZIP / PCRE-style) are not inventoried beyond crate `license =` SPDX (same bar as overlay cargo packages).

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `dev-util-autolith-seed`: LICENSE inventory (Autolith + installed `.qlot` + fff-c crate SPDX + overlay `COLL-Attribution`); private layout is share + libdir + `/usr/bin/autolith` wrapper with two dests.

## Impact

- **mndz-overlay**: Autolith ebuild revisions, `licenses/COLL-Attribution`, Manifest, package md5-cache. Two overlay commits.
- **mndz-overlay-assets**: none (no deps tarball republish).
- **mndz-overlay-manager**: planning artifacts and seed-spec delta only; no implementation in this change.
- **Operator**: full emerge of `-r2` (rebuilds natives and both cores) then `autolith --version`. Unset stale `AUTOLITH_SBCL_SOURCE_ROOT` / git safe.directory if they pointed at the old single prefix.
- **Downstream**: later Autolith PV bumps inherit LICENSE + two-dest body from the template (apply already preserves it).
