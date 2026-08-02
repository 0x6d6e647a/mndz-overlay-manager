## Why

When `update` applies a multi-PV `DepsAndAssets` package, a content-fix revision bump can delete the discovery-time donor ebuild path before a later unit materializes a **missing** newer PV that falls back to that path. The process then dies with an uncaught `openFile` IOException (observed on `dev-util/crush`: same run committed `0.82.0-r5`, then crashed opening `…-r4.ebuild`). Multi-PV Go packages need correct unit order and a structured hard-fail when no template exists.

## What Changes

- Order multi-PV `DepsAndAssets` apply units so **missing** planned PVs run **before** pure **content-fix** revision bumps (stable PV sort within each group).
- When the donor/template ebuild path for a unit is missing, hard-fail that unit with an actionable message instead of throwing an uncaught `openFile` / `IOException`.
- Keep per-PV commit-on-unit-success and exact-set prune after all planned PVs succeed.

## Non-goals

- Live re-selection of donor from a full package-dir scan every unit (optional follow-up; not required once missing runs before content-fix).
- Refreshing the snapshot `localPVs` list between units (not required for this failure mode).
- Folding multiple planned PVs into a single overlay commit.
- Package-specific hardcoding for crush or other packages.
- Changing runtime-lane planning, assets publish, or KEYWORDS assembly rules.

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `update-apply`: Multi-PV unit ordering (missing before content-fix); missing donor/template is an identifiable hard-fail class.
- `deps-assets`: Align apply sequencing for multi-PV materialize with the same missing-before-content-fix rule where that capability describes multi-unit apply.

## Impact

- **Code:** `Update.Apply.Materialize` (unit sort / partition of `needPVs`), `Update.Apply.OverlayWrite` (template existence check before read), possibly shared apply error helpers / cargo donor reads that share the same bare `readFile` pattern.
- **Tests:** Multi-PV fixture where local only has a revision needing content-fix and plan also has a missing newer PV; assert order and hard-fail on missing template.
- **Operator:** `update` on multi-PV DepsAndAssets packages (e.g. crush) completes missing PVs without crashing after a prior revision-bump unit; missing template yields a package hard-fail, not a process abort.
- **Docs:** README/CONTRIBUTING only if operator-facing recovery text is documented (likely none beyond hard-fail message).
