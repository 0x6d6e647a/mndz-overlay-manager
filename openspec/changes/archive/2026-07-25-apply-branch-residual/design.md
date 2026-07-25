## Context

Spine modules have high top-level definition coverage but mid alternatives and large absolute misses (Materialize, Deps.Plan, Check, Apply, GitMv, Ceilings). Locked T8 A+B and T9 A+B. Anti double-count: production HTTP/process closures owned by earlier waves.

## Goals / Non-Goals

**Goals:**

- Heat `applyOverlay` (jobs=1 and jobs>1)
- contentFix all four ecosystems (staged Go+Npm then Bun+Cargo)
- Ceiling discover residual with fakes/fixtures
- Materialize/GitMv branch residual
- Green floor-free gates

**Non-Goals:**

- Production process/HTTP adapter implementation
- Main extract/scoring
- Floors

## Decisions

### D1: Integration-primary

**Choice:** Multi-step apply/check/plan cases under Integration; pure compare/helpers under Unit if still cold.

### D2: applyOverlay jobs matrix

**Choice:** Land jobs=1 multi-package soft/hard mix first for determinism; add jobs>1 concurrent case before change is complete (same change, ordered tasks).

### D3: contentFix eco order

**Choice:** Go+Npm content-only + Ok/reusable flag first; then Bun+Cargo content-only in later tasks of the same change.

### D4: Ceilings via injectable portageq / fixtures

**Choice:** Empty-cache discover and non-Go runtime residual using fakes/fixtures—not live portageq production (process wave).

### D5: Materialize error arms

**Choice:** Controlled ApplyEnv fakes for plan-fail, builder fail already partly present, prune, missing token/assets, sidecar verify edges still yellow in HPC.

### D6: Success metric

**Choice:** Gates green; guidance ~+2.5–5.5 Overall; no floors. Change incomplete if jobs>1 or Bun/Cargo contentFix tasks skipped.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Concurrent applyOverlay flake under HPC | Stabilize jobs=1 first; careful asserts on jobs>1 |
| Fixture explosion for four ecos | Shared temp overlay helpers; minimal ebuild bodies |
| Double-count production adapters | Only domain fakes; no production* process/HTTP work |

## Migration Plan

1. applyOverlay jobs=1 Integration.
2. jobs>1 Integration.
3. contentFix Go+Npm then Bun+Cargo.
4. Ceilings + materialize/GitMv residual.
5. Coverage + hk check.

## Open Questions

None blocking.
