## Why

Go tree-lane planning probes `go.mod` for every comparable upstream tag before selecting lane targets. That is correct but slow: the UI steps through all historical releases even though lane selection only needs the newest version under each Portage Go ceiling. Frequent runs almost always need only the tip (or a short newest-first prefix). Early exit preserves the same targets while cutting probe work from O(all tags) to O(distance to a full lane set).

## What Changes

- Probe upstream `go.mod` files **newest-first** (list order is already PV-descending) and **stop** once every ceilinged lane has a target package PV.
- Keep full GitHub tag listing and PV sort unchanged (no partial pagination, no reverse page walks).
- Do **not** seed probes from local ebuilds; do **not** batch concurrent probe walks for early exit (sequential probes under the existing work budget are enough).
- Coarsen planning progress so all go.mod probing is **one** package step (not one step per tag).
- Functional lane targets remain identical to full-probe + `maxVersionUnder` for the same ceilings and parseable go_req values.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `go-tree-lanes`: Require newest-first probing with early exit when all ceilinged lanes are filled; update progress callbacks so probing is a single coarse phase rather than per-tag steps; clarify that concurrency/functional equivalence is about final lane targets, not probing every tag.

## Impact

- **Code**: `Update.Go.Plan` candidate building (`buildVersionCandidatesWithProgress` / planning loop); progress hooks in `Update.Check` (`goPlanProgress`); tests for planning and progress step totals.
- **Specs**: `openspec/specs/go-tree-lanes` progress and probe requirements.
- **Out of scope**: GitHub `/tags` pagination redesign, local-PV seed probes, batch probe windows, content-fix path changes beyond continued use of the go.mod cache for planned PVs.
