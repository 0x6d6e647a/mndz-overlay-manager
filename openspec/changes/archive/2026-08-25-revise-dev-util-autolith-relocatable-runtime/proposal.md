## Why

Dumped Autolith cores still resolve Lisp and Quicklisp paths from Portage `${S}` (`/var/tmp/portage/dev-util/autolith-…/work/…`). After emerge that workdir is gone (`noclean` is not a packaging contract), so session start dies: `The private fff helper is missing at ${S}/bin/autolith-search-worker`. The helper is already installed under `/usr/share/autolith/bin/`; `--version` never builds the tool registry so FHS/hygiene smoke missed it. Overlay users without leftover workdirs (X: artsi0m) cannot start Autolith. Hygiene `-r3` did not cause this; it is a relocatable-image gap on top of the two-dest layout.

## What Changes

- On the **live** Autolith PV (currently `0.32.2-r3`; if PV has moved, apply `-rN` on that live atom): replace `autolith-<PV>-r3.ebuild` with `autolith-<PV>-r4.ebuild`. **Runtime path relocation only.** Keep two dests (share Lisp / libdir compiled), LICENSE, KEYWORDS, SBCL floor, deps `SRC_URI`, and the pruned install set. Working tree has only `-r4` after the commit.
- **Active and recovery image entry** (before `main` / recovery commands): if dump-time source-root ≠ launcher source-root argument, relocate ASDF systems under dump-root onto the live source-root (`asdf:load-asd` of translated `.asd` files so `component-pathname` rebuilds), clear and reinitialize ASDF output-translations, set Quicklisp home to `<live-source-root>/.qlot/`, and set `*local-project-directories*` to a directory under the user’s XDG cache (not share). Do **not** hardcode `/usr/share/autolith` in dumped Lisp; follow the launcher argument. Do **not** rewrite SBCL contrib paths.
- **Compile-time debug namestrings:** while building cores, bind `sb-c:*source-namestring*` (or equivalent) so `"Defined in …"` names the live **share** dest (`${EPREFIX}/usr/share/autolith/…`), not `${S}`. Lisp dest only; not libdir.
- **`--from-source`:** install `share/.qlot/local-init/qlot-00-fhs.lisp` (sorts before `qlot-10-https.lisp`) that points `*local-project-directories*` at the same XDG cache directory. Share `.qlot` stays read-only. Do **not** chmod share or `touch` the share `system-index.txt`.
- Delta `dev-util-autolith-seed`. Seed identity remains v0.17.2 archaeology. Apply still only rewrites KEYWORDS, SBCL floor atom, and deps `SRC_URI`.
- Operator smoke: emerge `=dev-util/autolith-<PV>-r4`, then `timeout 5 autolith </dev/null` must not mention `/var/tmp/portage` or a missing fff helper. `--version` is not session proof. Operator may also run `autolith auth grok`. `--from-source` is **not** green on this atom (leaky 0.32.2 qlot confs wait for the next Autolith PV rematerialize).

## Non-goals

- No Autolith PV bump; no republish of `autolith-0.32.2-deps.tar.xz`; no ebuild rewrite of leaky `qlot.conf` / `source-registry.conf` (next PV rematerialize already owns that).
- No KEYWORDS / SBCL floor / LICENSE / FHS dest changes; no moving Lisp into libdir or cores into share.
- No extra apply rewrite fields; no manager Haskell.
- No Autolith upstream PR in this change (follow-up: wiki `handoffs/autolith-upstream-fix-followup.md`).
- No `FEATURES=noclean` as a contract; no making share writable; no installing emerge fasls under share or libdir to scrub `strings` of the core.
- No dedicated Autolith packaging-probe flag in this change.

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `dev-util-autolith-seed`: dumped cores and `--from-source` MUST NOT use Portage `${S}` (or `${T}` fasl cache) at runtime; ASDF/qlot Lisp paths follow the launcher share dest; Quicklisp local-projects index is XDG cache; session smoke is not `--version` alone.

## Impact

- **mndz-overlay:** `autolith-<PV>-r4.ebuild` (src_prepare patches and/or FILESDIR + `qlot-00-fhs.lisp`), Manifest, package md5-cache. One overlay commit. Delete the `-r3` filename; working tree has only `-r4`.
- **mndz-overlay-assets:** none.
- **mndz-overlay-manager:** seed-spec delta + Purpose line; `openspec validate` / `hk check`. No Haskell.
- **Operator:** full emerge of `-r4` (rebuilds natives and both cores) then `timeout 5 autolith </dev/null`. Optional `auth grok`. `--from-source` may still fail on leaky `/home/` qlot confs until the next Autolith PV.
- **Downstream:** later Autolith PV bumps inherit the relocatable body; next rematerialize supplies clean qlot confs. Autolith-shaped relocate is later sent upstream, then Gentoo forks drop.
