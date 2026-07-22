## Why

Same-PV content fixes for Go packages always write `-r1` from a bare planned PV, even when a local revision already exists. A second content fix then overwrites `pkg-X.Y.Z-r1.ebuild` instead of producing `-r2`, which violates the existing product rule that same-PV fixes should use a higher `-rN` when a revision is already present.

## What Changes

- When materializing a same-PV Go content/Manifest fix, choose the write PVR by taking the **highest local revision** for that PV and applying `nextRevisionVersion` to it (bare → `-r1`, `-r1` → `-r2`, …).
- Keep asset/release identity on PV without revision (`renderPVNoRev`); only the overlay ebuild filename and commit message version change.
- Add unit coverage for bare → `-r1` and existing `-r1` → `-r2` selection.

## Capabilities

### New Capabilities

_(none)_

### Modified Capabilities

- `go-vendor-assets`: Clarify that same-PV revision bumps advance from the highest local revision for that PV, not always from bare PV.

## Impact

- **Code:** `Update.Apply.materializeOne` (and a small pure helper for “highest local revision among same PV”); possibly export a testable pure function.
- **Tests:** `test/Main.hs` unit tests for revision selection.
- **Behavior:** Second (and later) same-PV content fixes produce new `-rN` files and remove the prior same-PV template when paths differ, matching existing overlay rewrite rules.
- **Not changed:** `GitMvAndManifest` (still no invented revision); asset tag/tarball naming; BDEPEND/go.mod rules.
