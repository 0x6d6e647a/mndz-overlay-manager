## 0. Prerequisites

- [x] 0.1 Confirm `pure-helpers-dedupe` and `runtime-naming-cleanup` are on the base branch

## 1. Extract Commit

- [x] 1.1 Create `Update.Apply.Commit` with `signedOverlayCommit`, `egencacheAndSignedCommit`, commit message helpers
- [x] 1.2 Wire cabal modules; keep re-exports from `Update.Apply` as needed
- [x] 1.3 Compile + run apply/commit-related tests

## 2. Extract GitMv

- [x] 2.1 Create `Update.Apply.GitMv` with GitMv path and md5 pre-mutation gate
- [x] 2.2 Update dispatch in `Update.Apply`
- [x] 2.3 Compile + run GitMv / md5-gate tests

## 3. Extract OverlayWrite

- [x] 3.1 Create `Update.Apply.OverlayWrite` with `overlayAfterAssets` and template/BDEPEND/KEYWORDS write path
- [x] 3.2 Compile + run content-fix / overlay write related tests

## 4. Extract Materialize

- [x] 4.1 Create `Update.Apply.Materialize` with materialize plan, distfile, reuse/full publish, step budgets, progress adapters
- [x] 4.2 Keep legacy test wrappers (`materializePlan`, `goPublishAndOverlay`, `contentFixNeeded`) as thin facades
- [x] 4.3 Compile + run multi-PV, reuse vs full, progress sequence, lock tests

## 5. Slim orchestration

- [x] 5.1 Leave `applyOverlay`, `applyPackagePhase1` (+ tracked), `ApplyEnv`, `foldExitHardFail` in `Update.Apply`
- [x] 5.2 Confirm no intentional behavior edits beyond moves
- [x] 5.3 Full `cabal test all` and `hk check`

## 6. Specs and handoff

- [x] 6.1 Keep `update-apply` layout-independence delta accurate
- [x] 6.2 Note final module map if it diverged slightly from design
- [x] 6.3 Sync `update-apply` delta at archive
- [x] 6.4 Ready to archive; next: `structured-domain-errors` and/or `library-api-encapsulation`
