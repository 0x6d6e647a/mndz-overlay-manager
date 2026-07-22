## Context

Same-PV Go content fixes call `nextRevisionVersion` on a **bare** planned PV (`Numeric comps Nothing`), so every fix becomes `-r1`. When local is already `X.Y.Z-r1`, apply overwrites that file instead of writing `-r2`. Specs already say “or higher `-rN` if a revision already exists”; the helper `nextRevisionVersion` already supports `r → r+1`, but `materializeOne` never feeds it the highest local revision.

## Goals / Non-Goals

**Goals:**

- Same-PV materialization write PVR = `nextRevisionVersion` of the highest local same-PV ebuild version.
- Bare local only → `-r1`; local max `-r1` → `-r2`; local max `-rN` → `-rN+1`.
- Pure, unit-testable selection (no IO).
- Keep assets/release identity on PV without revision.

**Non-Goals:**

- Changing `GitMvAndManifest` revision policy.
- Inventing revisions when materializing a **new** planned PV that is not already local.
- Multi-file retention of old revisions for the same PV after a successful rewrite (existing template-removal for same-PV remains).

## Decisions

### 1. Select write version from max local same-PV revision

**Choice:** Among `localPVs` with the same PV as the planned target (via `comparePV` EQ), pick the maximum by revision order: bare (`Nothing`) < `-r1` < `-r2` < …; then `writeVer = nextRevisionVersion maxLocal`.

**Alternatives considered:**

| Approach | Why not |
|----------|---------|
| Always `-r1` from bare (today) | Overwrites existing `-rN`; fails the “higher `-rN`” rule |
| Always bump only the template path’s revision | Template discovery order is not guaranteed max |
| Scan package dir inside `materializeOne` again | Redundant when `localPVs` already lists non-live versions for the package |

### 2. Pure helper next to `nextRevisionVersion` or in Apply

**Choice:** Add a small pure function (e.g. `nextWriteVersionForSamePV :: EbuildVersion -> [EbuildVersion] -> EbuildVersion`) either in `Update.EbuildEdit` (with `nextRevisionVersion`) or as a package-local pure helper exported for tests from `Update.Apply`. Prefer `Update.EbuildEdit` so revision policy lives with `nextRevisionVersion`.

Logic sketch:

```
if no local same-PV → bare planned PV (new materialization)
else → nextRevisionVersion (maxRevision among same-PV locals)
```

`materializeOne` already branches on `alreadyLocal`; fold that into the helper for one place.

### 3. Raw versions

**Choice:** Keep existing `nextRevisionVersion (Raw t) = Raw (t <> "-r1")` behavior; max among raws is best-effort (string identity / first same-PV). Numeric packages are the real product path.

## Risks / Trade-offs

- **[Risk] Stale `localPVs` mid multi-PV plan** → Mitigation: per-PV units are sequential; `localPVs` is captured once per plan, but each same-PV fix runs once per planned PV per run. A second run re-lists locals and will see `-r1` then produce `-r2`. Within one run a PV is only materialized once in `needPVs`. Acceptable.
- **[Risk] Both bare and `-r1` present** → Max is `-r1`; write `-r2`; template removal removes same-PV template when paths differ. Prune still only removes non-planned PVs, not same-PV extras; `overlayAfterAssets` already removes template when same PV and different path. Residual bare file could remain if template was `-r1` and bare also exists—pre-existing oddity. No new risk unique to max-revision selection beyond preferring bump from `-r1`.

## Migration Plan

No operator migration. Next `update` same-PV content fix after `-r1` yields `-r2` filenames instead of silent overwrite.
