## Context

See proposal.md for motivation. Multi-PV `DepsAndAssets` apply already materializes each needing PV as its own unit with commit-on-unit-success (`Update.Apply.Materialize.materializeDepsPlan`). Today `sortedPlanned` orders only by numeric PV, so a content-fix revision bump of an older local PV often runs before a missing newer PV. `findTemplate` falls back to frozen `PackageEntry.pePath`; `overlayAfterAssets` (and cargo donor reads) use bare `TIO.readFile` without existence checks. Hand-off details: `stale-donor-multipv-report.md` at repo root.

## Goals / Non-Goals

**Goals:**

- Order multi-PV units: missing before content-fix; stable PV order within each group.
- Hard-fail with an identifiable message when the template/donor path is missing; no process-killing `openFile` for that case.
- Preserve per-PV commits, prune-after-all-success, reuse vs full path, and ecosystem-agnostic spine behavior.

**Non-Goals:**

- Live re-pick of best donor every unit (C-live-donor).
- Refreshing `localPVs` between units.
- Single overlay commit for multiple PVs.
- Changing lane planning, KEYWORDS assembly, or assets publish rules.
- Overlay operator reset of partial crush commits (manual; outside this repo change).

## Decisions

### 1. Partition/sort in `materializeDepsPlan` (not re-plan)

**Choice:** After computing `needPVs = missingTargets ∪ contentFix` and filtering `glpEbuilds`, order planned units with a two-key sort:

1. Missing first (`not any (samePV pv) localPVs` / membership in `missingTargets`).
2. Then ascending PV (`comparePV` / numeric components as today).

**Alternatives:** (a) Fold multi-PV into one commit — rejected (breaks isolation). (b) Live donor re-list only — fixes crash after content-fix-first but still allows fragile order; agreed design prefers missing-first with hard-fail, not live-donor as the primary fix.

### 2. Content-fix vs missing classification

**Choice:** A PV in `missingTargets` is ordered as missing even if also listed in content-fix sets. Pure content-fix = needs work and has local same-PV.

**Rationale:** Matches operator meaning of “create new ebuild” vs “rewrite existing revision chain.”

### 3. Hard-fail at template read (C-hard-fail)

**Choice:** Before `TIO.readFile` on template/donor paths used for overlay rewrite (at least `overlayAfterAssets` after `findTemplate`; align cargo donor reads that share the same pattern), check existence; on miss return `ApplyHardFail` with a clear message (package key, planned PV and/or path). Prefer extending `ApplyUnitError` if that keeps messages consistent with other identifiable classes; plain `ApplyHardFail` text is acceptable if structured enum is heavier than needed.

**Alternatives:** Catch `IOException` globally — worse, masks bugs. Live-donor always re-list — out of scope.

### 4. Frozen `pePath` remains acceptable under new order

**Choice:** Do not change `PackageEntry` lifetime. Missing-first keeps discovery-time `pePath` valid while new PVs template; content-fix may then remove that path.

**Trade-off:** New PVs template from pre-content-fix body; apply already rewrites KEYWORDS/BDEPEND/SRC_URI for the planned PV.

### 5. Tests over full crush integration

**Choice:** Unit/integration-style tests with fake plan + temp package dir: local only `pkg-0.82.0-r4.ebuild` needing content-fix; missing `0.88.0`; assert missing unit observes r4 (or completes template read) before r4 is removed; second test asserts hard-fail when template path is absent without exception escape.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Content-fix-only multi-PV packages change relative order only by PV (unchanged) | Explicit scenario: all content-fix → ascending PV only |
| New PV templates slightly “stale” KEYWORDS from donor | Overlay rewrite sets planned KEYWORDS; not a correctness issue |
| Hard-fail path misses a donor read site | Grep for `findTemplate` / `TIO.readFile` on ebuild paths; cover OverlayWrite + cargo |
| Operators still see partial multi-PV success if later unit fails | Existing multi-unit isolation; document; exit 1 still folds hard-fail |

## Migration Plan

1. Implement order + hard-fail; tests; `hk check`.
2. No config migration.
3. Operators with partial overlay commits (e.g. content-fix committed, missing PV not) should reset or complete manually, then re-run `update` after this ships.
4. Rollback: revert the change; behavior returns to PV-only order (bug returns).

## Open Questions

None for implementation. Optional follow-ups (not blocking): live donor selection; `localPVs` refresh between units — see `stale-donor-multipv-report.md` §6.
