## Context

See `proposal.md` for why. Today Graph 1 (`Update.OverlayWaves.overlayCeilingProvider`) maps `DepsAndAssets Bun` → `dev-lang/bun-bin` only. Admit-when-ready withholds those consumers from **all** phase-1 work. Overlay signed commits already serialize on `aeOverlayLock`. DepsAndAssets prune is `extrasToDelete` = local PVs not in `glpUniquePVs`. GitMv renames newest and leaves siblings.

Living overlay-internal `DEPEND*` edges (mndz-overlay): ralph/opencode → bun-bin (also Graph 1); hk/mise → usage (USE-conditional, unversioned). Image emerge of qlot/node-gyp is Graph 2 and is not in consumer ebuilds.

## Goals / Non-Goals

**Goals:**

- Enforce atom closure at each signed overlay commit.
- Scan overlay-dir keys from to-be-written and remaining ebuilds; no edge table.
- Wait-if-selected-else-refuse at overlay write, **outside** `aeOverlayLock`.
- DepsAndAssets prune = lane unique PVs ∪ reverse-dep keep; GitMv rename-away guard.
- Keep Graph 1 technique-only; do not feed OverlayWaves from this parse.

**Non-Goals:**

- Hypo ceilings, plan-delta, auto-pull, resurrect missing PVs, `outdated`, check-cache, image file-gate, Portage solver, KEYWORDS visibility, subslots, eclass inherit, expanding `exposed-modules`.

## Decisions

### 1. New helpers, not OverlayWaves

**Choice:** Pure parse + PV match + keep-set in a library module used from apply/overlay-write and prune/GitMv. `classifyAdmit` / `overlayCeilingProvider` stay Graph 1.

**Why:** Mixing graphs in admit would withhold hk from materialize and serialize Cargo work for atoms that do not change planned PVs.

**Alternatives:** Extend `overlayCeilingProviderForKey` from scan (rejected: chicken-egg, hypo, mise-wait-on-usage). Declared `policyOverlayWaitsOn` map (forgettable; the bug is forgetting).

### 2. Scan overlay package directories, not `hardcodedPolicies` alone

**Choice:** An atom is overlay-internal iff `category/package` is an overlay package dir (same inventory `list` walks).

**Why:** Seed-only dirs still must close HEAD. Policy-only would miss unmanaged overlay packages consumers name.

**Alternatives:** Policy keys only (narrower, misses unmanaged dirs). Any cat/pkg in the string (false positives on comments if we scanned whole files — we scan DEPEND-family assignments only).

### 3. Check to-be-written bytes; remaining C from planned trees

**Choice:** For the unit about to commit, parse the ebuild text after rewrite (bun-bin BDEPEND insert included). For reverse-dep keep and rename-away, consumers are **planned remaining** trees (selected: post-apply exact-set/GitMv result; unselected: on-disk non-live).

**Why:** Scanning only pre-run disk misses manager-written atoms and keeps PVs for C ebuilds this run is about to delete.

**Alternatives:** md5-cache after egencache (eclass-expanded, but the invariant is ebuild text we commit; no inherit expansion). Pre-run snapshot only (wrong keep-set).

### 4. Wait before overlay lock; materialize may overlap

**Choice:** Graph 3 consumers stay in the apply job pool. Immediately before overlay mutation, wait on in-selection providers that must land first (terminal overlay outcome), re-read provider PVs, then take `aeOverlayLock` for egencache/commit. Never `wait` while holding that lock.

**Why:** Holding the overlay lock while waiting for P deadlocks (P needs the same lock). Graph 1 already solved bun-bin by not admitting ralph; Graph 3 must not copy that for usage.

**Alternatives:** Whole-package withhold via `classifyAdmit` (simpler, over-serializes). End-of-run check (violates commit-on-unit-success / mid-run HEAD).

### 5. Parser subset

**Choice:** DEPEND-family assignments, same-file `${RDEPEND}`-style expand, USE `? ( )` over-approx, `||` as one overlay-named branch, PV operators unversioned/`>=`/`<=`/`>`/`<`/`=`/`~` via existing `comparePV`. Ignore self-atoms. Strip `:=` as noise. Fail-closed on overlay-internal blockers, explicit non-`0` slots, unknown operators, unparseable assignments. No eclass inherit.

**Why:** Matches the living overlay; a solver is out of scope; fail-closed beats silent unsatisfiable HEAD.

**Alternatives:** Default IUSE evaluation (would drop hk completion usage — rejected suspenders). Full Portage atom parser.

### 6. B is prevent-delete

**Choice:** Keep-set cannot add a PV that is not on disk. Recovery for an already-missing pin is restore/relax, not `update`.

**Why:** Same as runtime-lanes “do not invent older locals.” Resurrect is a different product.

### 7. Tests without a live overlay

**Choice:** Fixture ebuilds and pure helpers for parse, match, keep-set, rename-away, cycle, fail-closed. Fake-ops apply for wait-before-lock and refuse-without-expand. `hk check` is the gate.

**Why:** Policy tests already avoid a live overlay; weeder stays entrypoint-oriented; parser stays `other-modules`.

## Risks / Trade-offs

- **[Risk] Toy parser misses a clever ebuild** → Fail-closed overlay write; fixtures for every DEPEND shape in mndz-overlay; no eclass expansion (cargo rust `||` is gentoo).
- **[Risk] USE over-approx keeps usage forever for default-off completions** → Tiny extra keep; that is the belt. Unversioned atoms still allow pruning old usage PVs.
- **[Risk] Overlay-write wait vs job slots** → Wait outside `--jobs` occupancy if the row is blocked on a provider (same as Graph 1 waiting SHALL NOT occupy a slot). Materialize already used a slot; overlay-write wait must not hold the overlay lock.
- **[Risk] Same-run prune order** → Compute B from planned remaining C, not pre-run C, so usage does not keep a PV only for an hk PV this run deletes.
- **[Risk] Double-path with bun-bin Graph 1** → Closure check is a no-op success when Graph 1 already ordered and `>=` still matches. Do not disable Graph 3 for bun-bin.

## Migration Plan

No overlay format migration. First `update` after ship only changes prune/rename/write-order when atoms would otherwise lie. Rollback is revert; trees already unsatisfiable stay refuse-until-restore (B does not resurrect).
