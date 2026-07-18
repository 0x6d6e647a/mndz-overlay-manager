## 1. Overlay lock and commit-on-unit helpers

- [x] 1.1 Add overlay git critical section to `ApplyEnv` (e.g. `aeOverlayLock :: MVar ()`) and wire it in `app/Main.hs` / test fixtures alongside `aeAssetsLock`
- [x] 1.2 Implement helper that runs `goAddAndCommit` under the overlay lock with GPG readiness (existing `GitOps` path)
- [x] 1.3 Adjust `ApplySuccess` usage so success means the unit is already committed (paths optional for tests/logging only; no deferred-commit contract)

## 2. GitMv commit-on-success

- [x] 2.1 After successful `ebuild … manifest` in `gitMvDo`, immediately signed-commit unit paths (old ebuild if renamed, new ebuild, Manifest) under overlay lock
- [x] 2.2 On commit/sign failure after mutation, hard-fail with half-applied warning (no success outcome)
- [x] 2.3 Remove GitMv reliance on phase-2 `commitSuccesses` for pending paths

## 3. Go multi-PV commit-on-success

- [x] 3.1 After successful overlay mutate + Manifest SHA512 verify in `overlayAfterAssets` (full and reuse), immediately signed-commit that PV’s paths under overlay lock
- [x] 3.2 In `materializePlan`, process planned PVs sequentially; on first hard-fail, stop further PVs for that package; return successes so far + failure (no prune)
- [x] 3.3 After all needed PVs succeed, run prune; if extras removed, signed-commit prune paths with message `category/package: prune obsolete ebuilds` (or agreed string); skip prune commit when no extras
- [x] 3.4 Remove multi-PV path piggyback onto last `ApplySuccess` for deferred barrier commit

## 4. Retire apply barrier commit phase

- [x] 4.1 Change `applyOverlay` so it no longer batch-commits pending `ApplySuccess` paths after concurrent package apply (barrier deferred-commit loop removed or reduced to assert/no-op)
- [x] 4.2 Ensure progress UI still reports package success/fail correctly without a separate post-apply commit step total (or adjust step counts intentionally)
- [x] 4.3 Update any code/comments that describe “phase 1 then phase 2 overlay commits”

## 5. Full BDEPEND vs go.mod content-fix

- [x] 5.1 Extend content-fix helpers so BDEPEND adequacy uses `goBdependMatches` against a known go.mod version (not presence-only of `dev-lang/go`)
- [x] 5.2 In apply and check content-fix, obtain go.mod version per present planned PV via probe cache (`PlanOps` / `fetchGoModVersion` / shared go.mod cache)
- [x] 5.3 Soft-skip “already matches Go tree-lane plan” only when BDEPEND matches known requirements (plus existing SRC_URI / KEYWORDS / Manifest rules)
- [x] 5.4 On overlay rewrite, keep `ensureGoBdepend`; hard-fail the PV when BDEPEND fix is required and go.mod version cannot be obtained (no silent skip)
- [x] 5.5 Align `outdated` content-fix / gap reporting with the same BDEPEND match rules (including ` [assets reusable]` when only overlay content/Manifest fix)

## 6. Tests

- [x] 6.1 Unit test: GitMv success invokes signed commit before returning `ApplySuccess`; no second deferred commit
- [x] 6.2 Unit test: two Go PVs sequential—commit after first; second dirty check sees clean tree (mock `goPathsDirty` / commit); two commits recorded
- [x] 6.3 Unit test: first Go PV succeeds, second hard-fails—first commit retained in outcomes; prune not run; later PVs not started
- [x] 6.4 Unit test: concurrent-style double overlay commit uses lock (no overlapping critical section; ordering under lock)
- [x] 6.5 Unit test: BDEPEND presence-only does not satisfy when version mismatches; mismatch triggers content-fix / not soft-skip
- [x] 6.6 Unit test: missing BDEPEND with known go.mod still needs-work; `ensureGoBdepend` insert/replace paths still pass
- [x] 6.7 Update existing tests that assume barrier `commitSuccesses` or presence-only BDEPEND content-fix

## 7. Quality gate

- [x] 7.1 Run `hk fix` / ormolu as needed; `cabal test all`; `hk check` until green
- [x] 7.2 Mark OpenSpec tasks complete only when the relevant gate is green
