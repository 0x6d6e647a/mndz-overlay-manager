## 1. Equal-ceiling skip

- [x] 1.1 Add a helper that, given overlay bun-bin metas and provider remote PV, returns either unchanged (on-disk `RuntimeCeilings` equal hypothetical ceilings) or the hypothetical ceilings to plan against; verify with unit tests in `test/Test/OverlayWaves.hs` (equal newest-PV replacement vs remote that raises a ceiling)
- [x] 1.2 Use that helper in `applyOverlayBlockIndication` so equal ceilings skip `planDepsPackageWithCeilingsFor`; verify `testOutdatedBlockedOn` still indicates blocked-on when ceilings differ, and a new test with bun-bin remote equal to overlay newest does not indicate blocked-on and does not call list/probe a second time
- [x] 1.3 Use the same helper in `refuseUnselectedProvider`; verify `testRefusePlanDelta` still refuses when hypo unique PVs differ, and a new test with equal ceilings does not refuse and does not re-list/re-probe
- [x] 1.4 Leave `planDepsHypo` on the selected-provider needs-work path; verify `testSelectedBunBinHypoWorkingPlan` still uses the hypothetical working plan
- [x] 1.5 When the skip fires, do not start a second ceilings/list/probe progress cycle for that package; verify existing progress tests still pass and equal-ceiling outdated does not emit a second “listing versions” status

## 2. In-run success memos

- [x] 2.1 Wrap production `dpoListVersions` with a process-lifetime success-only cache (`UpdateSource` key, do not store `Left`, lock not held across the network); verify a unit test that two successful lists of the same source call the base fetcher once, and that a `Left` is retried
- [x] 2.2 Wrap production `dpoFetchBunEngines` the same way (owner/repo/prefix/PV key); verify a unit test that two successful probes of the same key call the base fetcher once, and that a `Left` is retried
- [x] 2.3 Keep wrappers inside `productionDepsPlanOpsWithLatch` only so injected test `DepsPlanOps` stay uncached; verify existing CheckPlan bun tests still observe each list/probe they configure

## 3. Quality gates

- [x] 3.1 Run `openspec validate --change skip-equal-ceiling-hypo-plan --strict` and fix any delta/schema issues
- [x] 3.2 Run `hk check` until green (ormolu, tests including new skip/memo cases, stan/weeder if new exports)
