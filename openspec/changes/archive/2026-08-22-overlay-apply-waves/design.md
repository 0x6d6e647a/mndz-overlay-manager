## Context

See `proposal.md` — Why. Today `Update.Spine.runUpdatePhases` plans the full selection once (`planPackages` → `discoverBunBinCeilings` into `dpoBunCeilingsCache`), classifies, gates disk, then `applyOverlayFromPlan` runs `mapConcurrentlyN` over every `PlanNeedsWork`. Overlay `dev-lang/bun-bin` is `GitMvAndManifest`; Bun ceilings are overlay ebuilds (`runtime-lanes`). Check-cache deps fingerprints are the **consumer** tree only (`Update.CheckCache.computeFingerprint`). Independents and bun-bin share one apply pool with ralph/opencode.

Constraints: injectables (`DepsPlanOps`, `Fetcher`, `ReleaseOps`, `GitOps`); project-local quality tools; weeder roots stay entrypoint-oriented; prefer `other-modules` for new internals; no live overlay required for wait-edge tests.

## Goals / Non-Goals

**Goals:**

- Technique → overlay ceiling provider wait-edges; admit-when-ready job pool; re-plan after provider signed commit.
- Plan-delta refuse (fail-closed on provider latest-fetch); fingerprint A on overlay provider tree; one apply panel with waiting rows.
- Testable graph + fake-ops spine; README operator prose.

**Non-Goals:**

- Dockerfile / materialize-image ensure (one-line hook only).
- BDEPEND scan or a per-package edge map.
- Occupying `--jobs` slots while waiting; Kahn full-wave barriers; auto-expanding selection.
- Fingerprinting gentoo runtimes.

## Decisions

### D1: Wait-edges from `EcosystemSpec`, not a second map

**Choice:** `overlayCeilingProvider Bun = Just dev-lang/bun-bin`; other ecosystems `Nothing`. Invert the same function `planBun` already uses.

**Why:** Adding a Bun package cannot forget the edge. A per-package map duplicates `EcosystemSpec`. Ebuild scan lags (manager writes `bunBdependAtom` at apply).

**Alternatives:** Per-package map — rejected (forgettable). BDEPEND scan — deferred (`waves-scan-followup.md`).

### D2: Admit-when-ready; waiting is outside the job limiter

**Choice:** One `--jobs` pool for **admitted** phase-1 work. Independents + providers start together. Consumers of a needs-work in-run provider stay **out of the limiter** until that provider’s signed overlay commit (or the provider is a no-work skip). Then rediscover ceilings, re-plan, classify/preflight/disk for new units, admit into the same pool.

**Why:** bun-bin GitMv is cheap; ralph must not wait for mise. A Kahn barrier (all of wave 0 including cargo) is an operator-visible regression. Provider-first (everyone waits on bun-bin) is simpler but stalls independents; admit-when-ready is the spec’d scheduler.

**Alternatives:** Full wave-0 barrier — rejected. Provider-only then everyone else — rejected for v1 product, acceptable later if the job-pool is too hard.

**Job-slot rule:** A waiting row MUST NOT take a package job. `--jobs 1` still runs bun-bin while ralph waits.

### D3: Withhold even when the t0 consumer plan needs work

**Choice:** If the provider is selected and needs work, never mutate the consumer on the start-of-run plan. Re-plan after commit. Exact-set prune + commit-on-unit-success cannot apply an old PV set then a new one in one package apply.

**Why:** The silent skip (“already matches” at t0) is the main bug; applying the old needs-work plan is the other half.

### D4: Plan-delta refuse; hypothetical ceilings are GitMv-shaped

**Choice:** Hypothetical overlay ceilings = `discoverBunBinCeilings` on current metas with the newest non-live ebuild’s PV replaced by the provider’s GitMv remote latest (KEYWORDS unchanged). Plan-delta = unique planned PVs or needs-work differs. Fetch provider latest even when unselected (check-cache latest payload allowed). Do not add bun-bin to the selection.

**Why:** GitMv only renames newest; KEYWORDS come along. Refuse is a targeting error, not “ralph is current.”

**Alternatives:** Auto-pull bun-bin — rejected. Always refuse while provider is stale even without plan-delta — rejected. Fail-open on fetch error — rejected (operator chose fail-closed).

### D5: Fingerprint A — reuse package fingerprint on the overlay provider

**Choice:** Deps entries store the consumer `CacheFingerprint` **plus** `computeFingerprintFromDir` (or equivalent) of `dev-lang/bun-bin`. Missing component ⇒ miss. Do not fold into `content_hash`. Schema version may stay `1` with an additive field. Do not hash computed ceiling maps.

**Why:** Same helper as the consumer; over-invalidates on Manifest noise (safe). Catches GitMv of bun-bin in-process and across `outdated` then `update` within TTL. Ceiling-map JSON (`Eq`) is more precise but a new DTO; TTL already 5m for the ceiling-code-fix window.

**Alternatives:** Ceiling-map identity — deferred unless false misses hurt.

### D6: Invalidate in-process bun ceiling cache on provider success

**Choice:** After bun-bin signed commit, clear `dpoBunCeilingsCache` (or equivalent) before consumer re-plan. Rediscover from committed disk.

**Why:** Process-lifetime `MVar` would otherwise keep t0 ceilings even when check-cache misses.

### D7: One apply multi-progress panel

**Choice:** Keep a single `Updating packages` host. Withheld keys are waiting rows (name the provider) until admit, then ordinary in-flight rows. Total includes waiting keys. Planning stays a separate `Planning packages` phase (initial plan). Re-plan of a few consumers may be a short status on those rows or a nested plan step, not a second apply panel.

**Why:** Scheduler is not batched waves; a second panel would imply a barrier.

### D8: Spine re-entry after admit trigger

**Choice:** Extract a helper “prepare admitted DepsAndAssets units” (token/assets if newly needed, classify, docker if new full-path, disk gate for **new** units). Initial spine still plan → conditional preflight for **admitted** t0 needs-work → mutate admitted. On provider success, run the helper for newly needs-work consumers, then enqueue them.

**Why:** t0 may have only GitMv needs-work (no docker). Wave-1 ralph can invent full-path units. Fail consumers, keep provider commits.

### D9: Identifiable hard-fail classes

**Choice:** Reuse apply hard-fail folding (`foldExitHardFail`). New classes: overlay refuse/plan-delta; fail-closed provider fetch; provider hard-fail cascade. Messages name `dev-lang/bun-bin` and recovery (`update bun-bin` or untargeted `update`).

### D10: Module layout

**Choice:** Small pure wait-edge helper (technique → `Maybe PackageKey`, admit set from plan results) as `other-modules` (e.g. `Update.OverlayWaves` or under `Update.Apply`). Spine owns the job-pool/withhold loop. Do not expand `exposed-modules` unless the test-suite cannot import internally. No weeder `root-modules` blanket.

### D11: Materialize-image hook (unimplemented)

**Choice:** After a wave that mutates an overlay runtime used inside the (future) materialize image, `update` MAY call a re-entrant “ensure materialize image” function. That function does not exist. Do not specify Dockerfiles, prune, or XDG image layout here.

**Why:** Sibling explore owns image lifecycle; waves only leave the call site in comments/design.

### D12: Testing

**Choice:**

1. Pure: Bun → bun-bin edge; Cargo → none; admit graph; plan-delta predicate on two `RuntimeLanePlan`s.
2. Fake `Fetcher` / `DepsPlanOps` / `GitOps` / `ReleaseOps`: provider commit then consumer re-plan; t0 skip then needs-work; refuse; fail-closed; provider hard-fail cascade; check-cache miss when bun-bin files change; `--jobs 1` bun-bin while ralph waits.
3. No live overlay or live GitHub in CI.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Job-pool deadlock if waiting holds a slot | Waiting is not admitted; limiter only in-flight phase-1 |
| Check-cache serves t0 ralph plan after bun-bin GitMv | Fingerprint A + ceiling `MVar` clear |
| Rediscover after half-applied GitMv sees new filename | Rediscover only after signed success; cascade hard-fail |
| Late docker/disk fail after bun-bin committed | Spec’d; no rollback of commit-on-unit-success |
| Fingerprint A false misses on remanifest | Safe extra live plans; TTL 5m |
| Progress host assumes fixed total at panel open | Include withheld in total, or grow total on admit; tests for host |
| Weeder on new helper | `other-modules`; tests import the same component |

## Migration Plan

- Behavioral on `update` / `outdated`; no config keys.
- Existing deps cache entries without the overlay-provider field miss once (live plan, then rewrite).
- Rollback: revert the change; operators re-run `update` twice as today.

## Open Questions

None blocking. Exact blocked-on substring on the `outdated` line is spec-flex as long as `dev-lang/bun-bin` is indicated.
