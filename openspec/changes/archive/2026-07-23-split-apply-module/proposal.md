## Why

`Update.Apply` is a ~1.7k-line god module that owns GitMv, multi-PV materialize, reuse vs full asset publish, overlay ebuild write, signed commit locking, and progress step budgets. It is the highest maintainability and regression risk in the codebase. Existing scenario tests are strong enough to support a behavior-preserving split.

## What Changes

- Split `Update.Apply` into thin orchestration plus focused submodules, for example:
  - `Update.Apply` — `applyOverlay`, `applyPackagePhase1`, `ApplyEnv`, `foldExitHardFail`
  - `Update.Apply.GitMv` — GitMv path and md5 gate before mutation
  - `Update.Apply.Materialize` — plan materialize, distfile build, reuse/full publish, step budgets
  - `Update.Apply.OverlayWrite` — post-asset overlay ebuild/Manifest write and BDEPEND/KEYWORDS alignment
  - `Update.Apply.Commit` — signed overlay commit and package-scoped egencache+commit under locks
- Keep legacy test entry points (`materializePlan`, `goPublishAndOverlay`, `contentFixNeeded`) as thin wrappers until `library-api-encapsulation` decides their final home.
- **No intentional product behavior change:** same hard-fail / soft-skip / commit-on-unit-success / dirty checks / md5 gate / assets orphan flags / progress step counts.

## Program context

- **Part 3 of 8** of the post-audit quality program.
- **Apply order:** after `runtime-naming-cleanup`; before structured errors and API encapsulation.
- **Depends on:** `pure-helpers-dedupe`, `runtime-naming-cleanup` (land and archive first).

## Non-goals

- No algorithm changes to planning or ecosystem materialize.
- No progress soft-skip UX fix (part 6).
- No error ADT introduction beyond moving existing types (part 4).
- No cabal export shrinking (part 5).
- No test harness modularization (part 7).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `update-apply`: Add requirement that apply outcomes and gates hold independent of internal apply module layout.

## Impact

- **Code:** `src/Update/Apply.hs` and new `src/Update/Apply/*.hs`; cabal module list; imports in `app/Main.hs` and `test/Main.hs`.
- **Verification:** full apply-related test suite is the safety net; `hk check` required before done.
- **Downstream:** clearer homes for structured errors (part 4) and export policy (part 5).
