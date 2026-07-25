## Why

HPC is live and Overall product expression coverage is only ~45%. Before numeric floors, the suite should raise coverage with reasonable effort. Wave 1 takes the highest ROI pure and CLI surface so later waves are not blocked by trivial dark modules and parsers.

## What Changes

- Add **Unit** tests for pure/cheap library surfaces currently thin or dark:
  - `CLI.Parser`: `resolveColorMode`, `resolveJobs`, `execParserPure` on `parserInfo` (work commands, flags, targets, help paths as applicable)
  - `Update.Preflight`: tool list constants, expanded `checkToolsOnPath`, `validateAssetsPath`, `preflightUpdateTools` with injectable finders
  - `Update.TextUtil`: `stripSurroundingQuotes` both sides
  - `Update.GitHub`: expanded `stripAndParse` edge cases
  - `Update.SshAgent` pure helpers: `defaultIdentityCandidates`, more `parseIdentityFiles` cases
  - `Update.Check` pure helpers only: real `statusFromCompare`, `groupByPackage` / `groupNewest` edges (not the full check pipeline)
  - `Update.Http` / `Update.Npm` pure or thin unit paths where importable; design may expose testable surface if `other-modules` blocks tests
- Keep new cases under the **Unit** tasty group; Integration only if a pure helper cannot be reached otherwise (prefer Unit).
- Re-run `./scripts/coverage` and ensure `hk check` stays green.
- **No** operator-visible product behavior change; tests only (plus optional tiny export adjustments for testability).

## Program context

- **Wave 1 of 5** of the post-HPC coverage-maximization program (testmaxxing; all ecosystems treated equally in later waves).
- **Apply order:** 1 → `raise-coverage-ecosystem-builders` → `raise-coverage-check-and-deps-plan` → `raise-coverage-materialize-ecosystems` → `raise-coverage-agents-git-release`.
- **Depends on:** archived `hpc-test-coverage` (measurement already on main).
- **Baseline (pre-wave):** Overall ~45% expressions / ~37% alternatives / ~21% booleans (`coverage/summary.json`).

## Non-goals

- Ecosystem builders (`Npm.Cache` / `Bun.Cache` / `Cargo.Crates` full paths) — Wave 2.
- Full Check / Deps.Plan spine — Wave 3.
- Materialize apply for npm/bun/cargo — Wave 4.
- SSH/GPG process depth, Release HTTP create/delete, production Git bodies — Wave 5.
- Numeric coverage floors or ratchet baselines.
- System/E2E tests of the real executable / `app/Main`.
- Product CLI, config, or apply behavior changes beyond test-only export seams if required.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `test-coverage`: ADDED requirements that the suite exercises Wave-1 pure/CLI surfaces under Unit isolation and that coverage remains measurable without floors.

## Impact

- **Code:** primarily `test/**` (e.g. `Test.CLI`, `Test.Preflight`, `Test.Policy` / pure Check helpers, small new modules if cleaner); possibly `mndz-overlay-manager.cabal` if `Update.Http` / `Update.Npm` / `Update.TextUtil` need exposure for tests.
- **Quality:** `./scripts/coverage` and `hk check` must pass; Overall expression % expected to rise (horizon ~52–55%, not a gate).
- **Docs:** no README/CONTRIBUTING/AGENTS requirement (`project-docs` internal-only / test-only rule) unless cabal export policy text needs a CONTRIBUTING note (prefer not).
- **Downstream:** clears pure dark spots before Wave 2 ecosystem builders.
