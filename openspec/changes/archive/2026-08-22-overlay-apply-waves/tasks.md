## 1. Wait-edges and admit graph (pure)

- [x] 1.1 Add a technique → overlay ceiling provider helper (`DepsAndAssets Bun` → `dev-lang/bun-bin`; Go/Npm/Cargo/Sbcl → none) as `other-modules`; no per-package map; no ebuild parse
- [x] 1.2 Pure admit/withhold: given selection + initial plan results, compute admitted vs withheld vs refuse/fail-closed inputs; waiting does not consume a job slot
- [x] 1.3 Pure plan-delta: hypothetical ceilings = newest non-live provider PV replaced by GitMv remote (KEYWORDS unchanged); compare unique planned PVs / needs-work
- [x] 1.4 Unit tests: ralph/opencode wait on bun-bin; mise does not; new Bun package inherits the edge; provider already current does not withhold

## 2. Check-cache overlay-provider fingerprint

- [x] 2.1 Extend deps-entry fingerprint with the overlay ceiling-provider package fingerprint (same fields as the consumer: non-live PVs, source id, ebuild+Manifest hash); missing field is a miss
- [x] 2.2 Tests: bun-bin ebuild/Manifest change misses ralph deps hit within TTL; GitMv-only entries unchanged; old entries without the field miss

## 3. Plan-delta refuse and fail-closed

- [x] 3.1 When planning a Bun consumer, latest-check overlay bun-bin even if unselected (valid check-cache latest payload allowed)
- [x] 3.2 Plan-delta true → consumer `PlanHardFail` naming bun-bin and recovery (`update bun-bin` or untargeted `update`); do not add bun-bin to the selection
- [x] 3.3 Provider latest-fetch failure → fail-closed consumer hard-fail; do not apply on-disk-ceiling plan
- [x] 3.4 Tests: refuse with plan-delta; no-delta still applies against on-disk ceilings; fetch failure fail-closed; `update ralph-tui mise` refuses ralph and still plans mise

## 4. Spine: withhold, re-plan, re-entry

- [x] 4.1 `runUpdatePhases` / apply: admit-when-ready pool; withhold consumers while in-run provider needs work; do not mutate t0 consumer plans (including t0 needs-work)
- [x] 4.2 After provider signed overlay commit: clear in-process bun ceiling cache; rediscover overlay bun-bin ceilings; re-plan withheld consumers (fingerprint A must miss t0 deps entries)
- [x] 4.3 Re-classify, conditional token/assets/docker preflight, and disk gate for **new** consumer units; failures hard-fail consumers without rolling back the provider commit
- [x] 4.4 Provider apply hard-fail: do not rediscover dirty disk; cascade hard-fail withheld consumers naming the provider
- [x] 4.5 Fake-ops spine tests: same-run bun-bin commit then ralph higher PV; t0 ralph skip then re-plan needs-work; `--jobs 1` bun-bin while ralph waits; provider hard-fail cascade; late docker/disk fail keeps bun-bin commit

## 5. Outdated blocked-on

- [x] 5.1 `outdated` evaluates plan-delta for overlay-ceiling consumers; one consumer line **indicates** blocked on the provider; do not omit the consumer as current when plan-delta holds
- [x] 5.2 When bun-bin is in the check set, still emit its GitMv outdated line; provider latest-fetch failure is fail-closed for that consumer
- [x] 5.3 Tests for blocked-on indication and fail-closed check

## 6. Progress panel

- [x] 6.1 Single `Updating packages` panel: withheld rows in waiting presentation naming the provider; on admit become in-flight; waiting is not hard-fail; total includes withheld keys
- [x] 6.2 Tests for waiting vs hard-fail presentation and one-panel (no second apply host per wave)

## 7. Docs and quality gate

- [x] 7.1 Update `README.md` `update` / `outdated` prose: same-run overlay runtime order, blocked-on, refuse when the consumer is targeted without a stale overlay provider (`project-docs`)
- [x] 7.2 `openspec validate overlay-apply-waves --strict` clean
- [x] 7.3 `hk check` green; HIE rebuilt if modules move; no casual weeder/stan weakening; no `exposed-modules` expansion unless the test-suite requires it
