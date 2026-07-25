## Context

Post-`hpc-test-coverage`, Overall product coverage is ~45% expressions. Wave 1 targets highest ROI pure and CLI surfaces measured from `coverage/html` and `coverage/summary.json`: `CLI.Parser` (~5%), `Update.Preflight` (~19%), pure edges in GitHub/Ssh/Check/TextUtil, and importability of `Update.Http` / `Update.Npm` (`other-modules`).

Constraints: project-local tools only; `hk check` / `./scripts/coverage` remain the gate; Unit vs Integration taxonomy stays as in `test-coverage`; no floors; library encapsulation prefers not expanding `exposed-modules` without need.

## Goals / Non-Goals

**Goals:**

- Maximize HPC expression (and secondary alt/bool) coverage on Wave-1 modules with Unit-first tests.
- Prefer calling real library functions over reimplementing them in tests.
- Keep apply-ready quality gates green after the change.

**Non-Goals:**

- Ecosystem builders, Check/Deps.Plan spine, Materialize apply, agent process depth.
- Floors/ratchet, executable E2E, product behavior changes.

## Decisions

### D1: Unit-first, Integration only if necessary

**Choice:** All Wave-1 cases default to the **Unit** tasty group. Integration only if a helper is only reachable through a multi-module pipeline (should be rare).

**Rationale:** Matches isolation rule; pure helpers and parser pure evaluation are single-concern.

### D2: CLI.Parser via `execParserPure` + pure resolvers

**Choice:** Test `resolveColorMode`, `resolveJobs`, and parse outcomes with `Options.Applicative` pure helpers against `parserInfo`—not by spawning the binary.

**Alternatives:** process-level CLI tests (Wave non-goal / E2E).

**Rationale:** High coverage of parser definitions without flakiness; aligns with testmaxxing + reasonable effort.

### D3: Check pure only—no full outdated pipeline

**Choice:** Call `statusFromCompare`, `groupNewest`, `groupByPackage` (and thin pure edges) on the real `Update.Check` API. Do **not** implement full `checkOverlayWithDepsPlan` here (Wave 3).

**Rationale:** Avoids overlapping Wave 3 while still retiring pure darkness and partial fake-only habits for helpers that already exist on the product module.

### D4: Http/Npm reachability

**Choice:** Prefer testing through any already-exported path. If `other-modules` blocks needed Unit tests, **expose the module(s)** in the library cabal stanza for the test-suite (same encapsulation pattern as other test-imported modules), with minimal export list changes. Do not add a second internal library in this wave.

**Alternatives:** only indirect coverage via later Check fetcher tests (insufficient for Wave-1 zero modules).

**Rationale:** User asked for Unit tests on this surface; expose-for-tests is already how most product modules are tested.

### D5: Module placement in `test/`

**Choice:** Extend existing domain modules (`Test.CLI`, `Test.Preflight`, `Test.Ssh`, `Test.Policy` or Check-adjacent) when the file remains navigable; split a small pure module only if a file is already overloaded.

**Rationale:** Follows modular tasty layout without a suite restructure change.

### D6: Success metric

**Choice:** Wave done when tasks complete, `./scripts/coverage` and `hk check` pass, and targeted modules are no longer trivially dark (CLI.Parser not ~5%; Preflight/TextUtil/Http/Npm pure paths exercised). Percentage horizons (~52–55% Overall) are **guidance only**, not gate criteria.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Expanding `exposed-modules` for Http/Npm | Only if Unit tests require import; document in tasks; avoid weeder roots bloat |
| `execParserPure` brittle to help text changes | Assert structure/command constructors and key flags, not full help prose |
| Overlap with later waves | Explicit non-goals; no Materialize/plan/builder work |
| Shared huge import preambles in test files | Prefer minimal imports in new code; no mandatory preamble cleanup in this wave |

## Migration Plan

1. Baseline `./scripts/coverage` (optional snapshot note).
2. Add Unit tests per task list; fix any cabal export needs.
3. `./scripts/coverage` + `hk check`.
4. Archive after green; next session implements Wave 2 only.

Rollback: revert test (and any cabal export) commits.

## Open Questions

None blocking—export of Http/Npm decided by compile needs at apply time (D4).
