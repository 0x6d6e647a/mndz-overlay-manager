## Context

See proposal.md for motivation. Plan-delta for Bun consumers lives in `applyOverlayBlockIndication` (`outdated`) and `refuseUnselectedProvider` (`update` with bun-bin unselected). Both always call `planDepsPackageWithCeilingsFor` after `fetchOverlayProviderLatest` and `hypotheticalCeilings`. `planDepsHypo` (bun-bin **selected** and GitMv-outdated) is the working plan and stays on that path.

`productionDepsPlanOpsWithLatch` already wraps go.mod fetches with `withGoModCache` (success and failure). Tag listing and bun `package.json` probes have no process memo; a second plan for the same GitHub source repeats pagination and probes.

## Goals / Non-Goals

**Goals:**

- Shared equal-ceiling short-circuit for plan-delta in `outdated` and unselected `update` refuse.
- Compare **computed ceiling maps**, not a PV `>=` shortcut.
- Process-lifetime memo of **successful** `dpoListVersions` and bun engine fetches, same locking pattern as `withGoModCache` (lock not held across the network; first successful insert wins).
- When hypo is skipped, do not run a second “listing versions” / probe progress cycle for that package.

**Non-Goals:**

- Parallel `/tags` pages, prefix-filtered refs, on-disk tag lists, default TTL change.
- Caching `Left` list/probe results.
- Changing `planDepsHypo` when the provider is selected and needs work.
- Specifying the memos in product requirements.

## Decisions

### D1 — Ceiling-map equality is the skip predicate

**Choice:** After a successful provider latest-fetch, compute on-disk ceilings and hypothetical ceilings from the **same** overlay bun-bin metas (`computeCeilings` vs `hypotheticalCeilings`). If those `RuntimeCeilings` values are equal, treat plan-delta as false and return the on-disk report/plan without `planDepsPackageWithCeilingsFor`.

**Why not `comparePV` overlay newest vs remote?** Overlay-ahead would lower hypo ceilings and can still change the plan; a `>=` skip would hide that. Structural equality of the ceiling maps is exactly “the hypo planner’s ceiling input matches the on-disk plan.”

**Why not skip the bun-bin latest fetch?** Fail-closed on that fetch remains required.

### D2 — One helper for both call sites

**Choice:** Extract a small helper (likely on `Update.OverlayWaves` or next to the two call sites) that, given overlay metas and remote PV, either returns `CeilingsUnchanged` or the hypothetical `RuntimeCeilings` to plan against. `applyOverlayBlockIndication` and `refuseUnselectedProvider` both use it. `planDepsHypo` does **not**.

**Alternative:** Duplicate the `Eq` test in both modules — rejected; the skip is easy to get out of sync.

### D3 — Success-only in-run memos on production ops

**Choice:** Wrap `dpoListVersions` and `dpoFetchBunEngines` in `productionDepsPlanOpsWithLatch` the way `withGoModCache` wraps go.mod, except **do not store `Left`**. A later call for the same key after a failure hits the network again. Tests that inject `dpoListVersions` / bun fetch stay uncached.

**Why wrap all `dpoListVersions` (including npm)?** One wrapper; npm is a single registry GET. GitHub-only would be an extra branch with no payoff.

**Why not cache `Left` like Go?** Hypo is not a retry of a failed list. Sticky failures would only matter if a later caller asked for the same source after a `Left`; that path is unused. Caching `Right` is the bun hypo win when ceilings **did** move.

**Keying:** `UpdateSource` for lists; owner/repo/prefix/PV (existing bun probe arguments) for engines.

### D4 — Progress follows whether hypo runs

**Choice:** If the skip fires, do not start a second ceilings/list/probe progress cycle for that package. If hypo still runs and the list memo hits, the existing “listing versions” step may complete immediately; do not add a “cached” status string.

### D5 — Tests lock skip and memos separately

**Choice:** Plan-delta tests: bun-bin remote yields equal ceilings → list/probe callback counts stay at one walk; no blocked-on / no refuse. Ceilings differ → second walk still happens; existing blocked-on and refuse tests remain. Wrapper unit tests: second successful list/probe for the same key does not call the base fetcher; a `Left` is not reused.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| `RuntimeCeilings` `Eq` misses a case that would have changed the plan | Same metas snapshot; `hypotheticalCeilings` only replaces newest non-live PV. If that replacement does not change per-arch max PVs, the planner cannot select a different set. |
| Overlay-ahead (remote lower than overlay newest) still replans | Intended; ceilings differ. Not a skip. |
| Memo first-insert race caches a success while a concurrent fetch is in flight | Same as `withGoModCache`; bun hypo is sequential for one package. Distinct packages do not share GitHub sources today. |
| Injected test ops accidentally get production memos | Wrappers live only in `productionDepsPlanOpsWithLatch`. |

## Migration Plan

- Library/CLI behavior only; no config or overlay format change.
- Ship behind `hk check`. Rollback is revert.

## Open Questions

None.
