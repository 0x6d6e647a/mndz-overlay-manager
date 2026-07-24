## Context

The quality pipeline (`hk.pkl`) already blocks on ormolu, `cabal build all && cabal test all`, hlint, stan, and weeder. The tasty suite under `test/` is domain-organized (Config, Apply, Lanes, …) with a mix of pure cases, fixture reads, and multi-module apply/plan tests using injectable seams (`PlanOps`, `ApplyEnv`, mock egencache). There is no HPC instrumentation, no coverage report artifact, and no Unit/Integration taxonomy in the suite.

GHC ships `hpc`; Cabal supports `--enable-coverage`. Exploration agreed: lean fully into HPC (expressions, alternatives, booleans), fold property tests into Unit, defer numeric floors/ratchet to a follow-up once metrics exist, measure product modules under `src/` (and `app/` when instrumentable), exclude test-only scaffolding such as `Update.Apply.TestSupport` from the product denominator.

## Goals / Non-Goals

**Goals:**

- Instrumented test runs via Cabal HPC that remain the correctness gate (no separate uninstrumented test step in the hook path).
- Non-coverage `cabal build all` retained so HIE for stan/weeder stays stable and independent of `-fhpc` objects.
- Reports: Overall + Unit + Integration rows; HPC columns expressions, alternatives, booleans (declarations optional).
- Human HTML markup and machine-readable summary under a gitignored output location.
- Tasty (or equivalent) structure so Unit vs Integration attribution is deterministic and documented.
- hk pre-commit / `hk check` invoke coverage generation; phase-1 failure modes are test failure or report generation failure only.
- CONTRIBUTING documents the new pipeline steps and how to run coverage locally.

**Non-Goals:**

- Coverage floors, ratchet baselines, or committed percentage policy.
- Assembly/MC/DC, line-primary metrics, mutation testing.
- System/E2E process tests of the real executable (may leave `app/Main` under-covered).
- Installing extra coverage tools into `.tools/bin` (HPC is part of GHC).
- Multiple Cabal `test-suite` stanzas unless tasty tagging proves insufficient during implementation.

## Decisions

### D1: Coverage engine = GHC HPC via Cabal

**Choice:** `cabal test all --enable-coverage` (and companion `hpc report` / `hpc markup`).

**Alternatives:** Stack coverage wrapper (not used here); third-party line tools (poor Haskell fit); binary/asm instrumentation (out of scope).

**Rationale:** Already on the machine with GHC 9.10; Cabal nix-style builds keep coverage-flagged units separate from normal objects.

### D2: Pipeline shape (strict, single test run)

**Choice:**

```
tools-preflight → ormolu → cabal build all
  → coverage entrypoint (test --enable-coverage + reports)
  → hlint → stan → weeder
```

Replace the current combined `cabal build all && cabal test all` step with an explicit non-coverage build for HIE and a coverage-enabled test+report step (implementation may use one hk step or two, as long as order and HIE freshness hold).

**Alternatives:** (B) uninstrumented test *and* coverage (double runtime); coverage only on `hk check` not pre-commit.

**Rationale:** User preference for strictness; one instrumented suite is enough for correctness if green; avoids paying for two full test runs.

### D3: Test taxonomy = Unit + Integration + Overall

**Isolation rule:**

- **Unit:** single library concern; no multi-step product pipeline (apply/plan/commit spine); I/O limited to reading small committed fixtures or pure memory; includes property tests (`testProperty` / QuickCheck) as a technique under Unit.
- **Integration:** multi-module workflow; temp overlay mutation; `ApplyEnv` / `PlanOps` / runners / multi-phase behavior.

**Property:** technique axis, not isolation axis → no separate coverage row.

**Attribution mechanism (preferred):** restructure `test/Main.hs` (and module exports if needed) so top-level tasty groups are named `Unit` and `Integration`, enabling:

1. Full suite run → Overall `.tix` / report  
2. Filtered runs (`tasty -p` / pattern for Unit and Integration) → per-level `.tix`  
3. Summaries written for all three rows  

If filtered runs double wall time unacceptably, document a fallback (single full run for Overall only + static classification metadata)—but default is real per-level tix so “coverage by unit tests” is honest.

**Config / read-only fixtures:** Unit under the refined rule (e.g. `loadConfig` on committed TOML fixtures; read-only fixture overlay discovery).

### D4: Report artifacts and location

**Choice:**

- Output root: repository `coverage/` (gitignored), e.g. `coverage/html/`, `coverage/summary.json` (or XML from `hpc report --xml-output` plus a thin normalization script), and optional text printed to the gate log.
- Script: `scripts/coverage` (or `scripts/run-coverage`) invoked by hk; discovers `.tix`/`.mix` under `dist-newstyle`, runs `hpc`, writes summaries.
- No committed HTML or tix; no baseline file in this change.

**Rationale:** Matches `.hie/` / `.tools/` “generated local” pattern; machine summary enables a later floor script without redesign.

### D5: Product denominator and excludes

**Include:** library modules under `src/` that are product code; executable modules under `app/` when present in the coverage map.

**Exclude from scored denominator:** `Update.Apply.TestSupport` and any pure test-double modules under `src/` that exist only for harness injectability. Document the exclude list in the script and CONTRIBUTING.

**Rationale:** Scaffolding would inflate or drag product % without reflecting shipped behavior.

### D6: OpenSpec shape

**Choice:** New living capability `test-coverage` for metrics semantics; delta on `git-hooks-quality-gates` for pipeline wiring. CONTRIBUTING updates follow existing `project-docs` triggers (no project-docs requirement delta).

### D7: Phase-1 success vs floors

**Choice:** Gate fails if tests fail or the coverage entrypoint cannot produce the required reports. Gate does **not** compare percentages to a floor.

**Rationale:** Explicit product decision—measure first, set floors after data.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Instrumented tests slower or flaky | Keep same suite logic; fix flakes; accept modest slowdown for quality |
| First coverage build expensive | Separate Cabal plan hash; incremental after warm cache; document in CONTRIBUTING |
| HIE / coverage object confusion | Always run non-coverage `cabal build all` before stan/weeder; never point stan at HPC-only trees |
| Filtered Unit/Integration runs triple test time | Start with structured groups; if too slow, Overall from full run + optional per-level on demand—prefer full honesty for hk check unless measured pain |
| `app/Main` near-zero coverage | Accept and surface in reports; future system tests out of scope |
| Exclude list rot | Keep excludes in one script constant + CONTRIBUTING note |
| Cabal/HPC path fragility across dist-newstyle layouts | Script locates tix via known Cabal layout patterns; fail clearly if missing |

## Migration Plan

1. Classify tests; restructure tasty tree (`Unit` / `Integration`).
2. Implement `scripts/…` coverage runner + gitignore.
3. Wire hk: build all → coverage test+report → analyzers.
4. Update CONTRIBUTING pipeline table and commands.
5. Run full `hk check`; fix any instrumentation or path issues.
6. Do **not** introduce floors until a later explore/change with real summary numbers.

Rollback: revert hk step to `cabal build all && cabal test all`, remove coverage script invocation; leave test grouping (harmless) or revert if desired.

## Open Questions

None blocking implementation. Follow-ups after metrics land:

- Absolute floors and/or ratchet baseline (committed small JSON/TOML).
- Whether System/E2E suite is worth adding for `app/Main`.
- Whether per-level filtered runs stay in the hot path or become optional.
