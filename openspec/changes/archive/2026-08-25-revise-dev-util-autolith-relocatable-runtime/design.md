## Context

See `proposal.md` for motivation. Live overlay atom at proposal time is `dev-util/autolith-0.32.2-r3` (pruned two-dest install). Seed identity in `dev-util-autolith-seed` remains v0.17.2; apply already preserves template body and rewrites only KEYWORDS, SBCL floor atom, and deps `SRC_URI`.

Cores are dumped in `src_compile` from `${S}` while Lisp will run from `/usr/share/autolith`. Wrapper already passes share as `--end-runtime-options` and exports `AUTOLITH_SOURCE_ROOT`. `configuration-create` honors that env; `search-worker-create` uses `asdf:system-source-directory` only. Quicklisp `*local-project-directories*` and ASDF output-translations are Lisp state inside the core.

Deps tarball `autolith-0.32.2-deps.tar.xz` still has `/home/mndz/quicklisp/...` in qlot confs. That tarball is **not** republished; `--from-source` is not green on `-r4`.

OpenSpec lives only in mndz-overlay-manager. Overlay implementation lands in mndz-overlay. No manager Haskell. Autolith-shaped relocate is a later upstream PR (`handoffs/autolith-upstream-fix-followup.md`); this change is a Gentoo patch so overlay users are unblocked.

## Goals / Non-Goals

**Goals:**

- One overlay commit: `-r3` → `-r4` on the live PV (relocatable image entry, debug namestrings, Quicklisp index off share).
- Seed-spec delta + Purpose line so later apply copies the relocatable body.
- Operator session smoke on `-r4` (`timeout 5 autolith </dev/null`), not `--version` alone.

**Non-Goals:**

- Autolith PV bump, deps republish, ebuild qlot-conf rewrite.
- FHS dest / LICENSE / KEYWORDS / SBCL / apply-field changes.
- Upstream Autolith PR; packaging-probe CLI flag; installing emerge fasls.

## Decisions

### 1. Live PV is `-r4`, not wait for the next Autolith tag

- Replace `autolith-0.32.2-r3.ebuild` with `autolith-0.32.2-r4.ebuild` (or `-rN` on whatever PV is live).
- Unblocks session start without a rematerialize. Next PV (separate change, operator intends immediately after) supplies clean qlot confs.
- **Alternative — wait for the next Autolith tag:** rejected; artsi0m’s crash is independent of PV and the leaky tarball.

### 2. Image entry translates dump-root → launcher source-root, no hardcoded share path

Stash dump-time `${S}` truename in the image when saving cores. On `active-image-main` and `recovery-main`, after the CLI source-root is known and **before** `main` / recovery commands (git probe may skip):

If live source-root ≠ dump-root:

1. For each loaded ASDF system whose source file is under dump-root, `asdf:load-asd` the translated `.asd` (rebuilds `component-pathname`). Do **not** rewrite SBCL contrib pathnames.
2. `(asdf:clear-output-translations)` then `(asdf:initialize-output-translations)`.
3. Quicklisp home → `<live-source-root>/.qlot/` (read-only dist on the package).
4. `quicklisp-client:*local-project-directories*` → `uiop:xdg-cache-home` + `autolith/qlot-local-projects/` (create the directory). **Not** share `local-projects/`.

If dump-root equals live root: no-op.

- **Alternative — hardcode `/usr/share/autolith` in Lisp:** rejected; second source of truth vs wrapper/`EPREFIX`; prefix and tests would drift.
- **Alternative — slot-setf `system-source-directory` only:** rejected; `lisp.source` on qlot deps uses `asdf:component-pathname`.
- **Alternative — bind-mount `${S}` onto share during compile:** rejected; fights `FEATURES=userpriv`.
- **Alternative — skip emerge-time cores / force `--from-source`:** rejected; C lean A stays; `--from-source` is also broken on this tarball.

### 3. Two callers for the Quicklisp index policy

Dumped cores never load `.qlot/local-init/`. `--from-source` never runs `active-image-main` before `setup.lisp`.

- Cores: decision 2 step 4.
- `--from-source`: ebuild installs `.qlot/local-init/qlot-00-fhs.lisp` (sorts before `qlot-10-https.lisp`) that only `setf`s `*local-project-directories*` to the same XDG cache path.

`.qlot/` is gitignored; write `qlot-00-fhs.lisp` after the deps `.qlot` is copied in `src_compile` (and it is installed with that tree). Autolith Lisp patches MUST be applied in `src_prepare` **before** git fabricate so HEAD matches share.

- **Alternative — `touch` share `system-index.txt` after install:** rejected; Portage directory mtime races.
- **Alternative — chmod share writable:** rejected; FHS.

### 4. Compile-time debug namestrings use the live share dest (ebuild-known)

`sb-c:*source-namestring*` is a single string per compile. Inject an ASDF around-compile (or equivalent) for compiles whose pathname is under `${S}`: set the namestring to the same relative path under `${EPREFIX}/usr/share/autolith`. That is the allowed case of the **ebuild** knowing the Lisp dest. Dumped Lisp still relocates via the launcher argument.

Do not point namestrings at libdir. Do not install emerge fasls.

- **Alternative — leave `"Defined in ${S}/…"`:** rejected; operator asked this in scope; backtraces would still name the workdir.

### 5. Patch mechanism and apply

Prefer ebuild `src_prepare` patches / small Lisp snippets in the template body (apply copies the body; pruneExtras only deletes obsolete ebuild filenames). `qlot-00-fhs.lisp` may be `cat`’d in the ebuild rather than `FILESDIR` so later PV bumps do not depend on an extra overlay file.

No manager Haskell. Seed Purpose (living spec) gains relocatable runtime when applying this change’s spec work; deltas do not replace Purpose.

### 6. Smoke is session start

`application-create` → `make-default-tool-registry` → `search-worker-create` runs before the TUI. `timeout 5 autolith </dev/null` is enough; a TTY/timeout failure after that is still a pass if `/var/tmp/portage` and “fff helper is missing” are absent. Operator may `auth grok`. `--from-source` is not a `-r4` gate.

## Risks / Trade-offs

- **[Risk]** `asdf:load-asd` misses a cached pathname and `lisp.source` still opens `${S}` → **Mitigation:** load-asd is the chosen mechanism; session smoke catches the helper; follow-up Autolith PR can add a probe that prints asdf paths.
- **[Risk]** `--from-source` still dies on leaky `/home/mndz` qlot confs → **Mitigation:** accepted; next Autolith PV rematerialize; `qlot-00-fhs` still lands so the writable-index hole is gone.
- **[Risk]** Git handshake fails because Lisp patches landed after `git add` → **Mitigation:** `src_prepare` before fabricate (already the hygiene order).
- **[Risk]** Around-compile misses some fasls; `strings` of the core still shows `${T}` → **Mitigation:** accepted for archaeology; output-translation reinit is the runtime fix; do not install fasls.
- **[Risk]** `-r4` rebuild is long (natives + both cores) → **Mitigation:** expected; smoke is not Manifest-only.
- **[Risk]** Direct `/usr/share/autolith/bin/autolith` without wrapper → **Mitigation:** already accepted in FHS; launcher still passes share as source-root so relocate still runs if cores are found via env.

## Migration Plan

1. Overlay: `autolith-<PV>-r4.ebuild` (image-entry relocate, namestrings, `qlot-00-fhs`), Manifest, package cache; delete `-r3` filename; one commit.
2. Manager: seed-spec delta + Purpose line; `openspec validate` / `hk check`. No Haskell.
3. Operator: `emerge -av1 =dev-util/autolith-<PV>-r4` then `timeout 5 autolith </dev/null` (optional `auth grok`).
4. Next Autolith PV bump (separate change): rematerialize clean qlot confs; `--from-source` can finish; apply copies the `-r4` body.
5. Later: Autolith upstream PR; overlay drops duplicated patches (wiki handoff).

Rollback: previous git revision still has `-r3`; working tree after this commit has only `-r4`.

## Open Questions

(none)
