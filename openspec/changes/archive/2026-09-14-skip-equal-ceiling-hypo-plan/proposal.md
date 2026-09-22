## Why

`outdated` (and `update PACKAGE` refuse) always runs a second runtime-lane plan against hypothetical bun-bin-at-remote ceilings, even when that remote cannot change overlay bun-bin ceilings. For high-tag Bun packages (`opencode`, `ralph-tui`) that second walk re-paginates GitHub tags and re-probes `package.json`, so a check that already has a valid on-disk plan still stalls on “listing versions.” Plan-delta cannot hold when the two ceiling maps are equal; the extra walk is wasted and can fail-close a package whose on-disk plan already succeeded.

## What Changes

- After fetching the overlay wait-edge provider’s GitMv latest (fail-closed unchanged), compute hypothetical ceilings as already specified. **If those ceilings equal on-disk ceilings, plan-delta does not hold.** Do not re-list upstream versions or re-probe per-PV metadata for that delta check. `outdated` keeps the on-disk result (no blocked-on). Unselected-provider `update` may apply the on-disk plan (no refuse from plan-delta).
- When hypothetical ceilings **differ**, run the hypo plan and compare as today (blocked-on / refuse when delta holds).
- When bun-bin is **selected and GitMv-outdated**, the hypothetical **working plan** is unchanged: still required, still not stored in the check cache.
- Implementation (not a spec requirement): reuse **successful** in-command tag lists and bun `package.json` probes so a hypo walk that still must run does not download the same GitHub pages and files twice. Do not persist those memos; do not remember failures.

## Non-goals

- Parallel GitHub `/tags` pagination, prefix-filtered refs, or any other listing transport.
- On-disk tag-name cache; default `check-cache-ttl` change; caching list/probe failures.
- Weaker Cargo MSRV probing at `outdated` time.
- Changing needs-work rules, blocked-on stdout shape, refuse messages, or fail-closed when provider latest cannot be fetched.
- Skipping hypo when bun-bin is selected and needs work.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `overlay-apply-waves`: Plan-delta evaluation MAY conclude that delta does not hold when hypothetical overlay ceilings equal on-disk overlay ceilings, without a second list/probe walk.
- `outdated-command`: The same equal-ceiling short-circuit applies to blocked-on evaluation (still latest-check the provider; still fail-closed on that fetch).

## Impact

- **Code:** `Update.Check.applyOverlayBlockIndication`; `Update.Apply.Plan.refuseUnselectedProvider`; production `DepsPlanOps` wrappers for successful `dpoListVersions` and bun engine fetches (same process-lifetime pattern as `withGoModCache`).
- **Tests:** Ceiling-equal skip (no second list/probe; no blocked-on / no refuse); ceilings-differ still hypo-plans; fail-closed on provider latest; in-run success memo (same source listed once; same bun probe key fetched once). Injected test listers stay uncached.
- **Docs:** No README/CONTRIBUTING/AGENTS update required (no CLI, config, or operator stdout shape change).
- **Operator:** `outdated opencode` / `outdated ralph-tui` when overlay bun-bin already matches remote latest is one plan walk instead of two. Blocked-on and `update ralph-tui` refuse still appear when a newer bun-bin would change the plan.
