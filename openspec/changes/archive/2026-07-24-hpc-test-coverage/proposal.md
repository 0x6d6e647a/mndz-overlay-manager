## Why

The project has a solid blocking quality pipeline (format, test, lint, static analysis) but no measurable view of how much product code the tasty suite actually exercises. Without HPC metrics—and without a breakdown by test isolation level—coverage floors, ratchet policies, and “does unit vs integration pull their weight?” questions cannot be answered with data. This change lands the measurement and reporting infrastructure first so floors and ratchets can be chosen later from real numbers.

## What Changes

- Add **Haskell Program Coverage (HPC)** as the project’s coverage engine (Cabal `--enable-coverage`); no assembly/MC/DC or non-HPC metrics.
- Produce **human (HTML markup) and machine-readable** coverage summaries for HPC dimensions that are first-class: **expressions**, **alternatives** (branch-like), and **booleans** (guards); top-level declarations optional in reports.
- Break reports down by test isolation level: **Unit**, **Integration**, and **Overall** (union). Property-based tests fold into Unit (technique, not a separate coverage row).
- Classify existing tasty tests under a documented Unit vs Integration rule; restructure or tag the suite so per-level runs (or equivalent attribution) are possible.
- Wire coverage into the **hk** quality pipeline: normal `cabal build all` for HIE, then `cabal test all --enable-coverage` as the test gate (single instrumented test run; no double uninstrumented+instrumented suite).
- Phase 1 gate success means tests pass under coverage and reports are produced successfully—**not** numeric floors.
- Gitignore generated coverage artifacts (`.tix`, HTML, ephemeral summaries). No committed baseline/ratchet file in this change.
- Document contributor workflow in `CONTRIBUTING.md` (and thin AGENTS pointer if needed).

### Non-goals

- Numeric coverage floors, ratchet / “must not decrease,” or committed baseline policy (follow-up after metrics exist).
- Assembly-level, MC/DC, line-as-primary-metric, or non-HPC tooling.
- System/E2E tests that spawn the real `mndz-overlay-manager` binary (future; `app/Main` may remain low-coverage until then).
- Separate Cabal test-suites unless tagging proves insufficient (prefer tasty structure first).
- Mutation testing, performance/security suites, or expanding product CLI behavior.

## Capabilities

### New Capabilities

- `test-coverage`: HPC instrumentation path, report artifacts (HTML + machine summary), Unit/Integration/Overall breakdown, product-module scope and exclude list (e.g. TestSupport), phase-1 success criteria without floors.

### Modified Capabilities

- `git-hooks-quality-gates`: Blocking pipeline uses coverage-enabled tests (with separate non-coverage build for HIE) and produces/requires successful coverage reporting as part of the gate.

## Impact

- `hk.pkl` pipeline ordering and the `cabal-test` (or successor) step.
- `test/Main.hs` and/or test module grouping for Unit vs Integration attribution.
- New script(s) under `scripts/` for coverage run + report generation (project-local; no ambient PATH tool install for HPC—HPC ships with GHC).
- `.gitignore` for coverage outputs under a dedicated directory (e.g. `coverage/`) and/or dist-newstyle tix handling as designed.
- `CONTRIBUTING.md` quality pipeline table and day-to-day commands (required by existing `project-docs` triggers when the pipeline changes); thin `AGENTS.md` pointer only if preferred gate commands change.
- No change to operator CLI, config keys, or runtime overlay behavior.
- Slightly higher gate cost on first coverage build; instrumented test runtime thereafter.
