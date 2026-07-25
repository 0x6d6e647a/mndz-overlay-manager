## Context

Post raise-coverage waves, Overall product HPC coverage is ~65% expressions. Residual pure/thin-IO library surface remains cold in modules such as `Config.Loader` (~49% expr), `CLI.Parser` residual (~76% but still miss help/verbosity edges), `Logging.Bootstrap`, `Overlay.Validation`/`Overlay.Version`, `Update.Auth`, and `Update.Types` helpers. This change is wave 1 of a multi-change testmaxxing program (one OpenSpec change per wave). Floors and gate percentage thresholds are out of program scope.

Constraints: Unit vs Integration taxonomy unchanged; no live network; project-local tools only; `hk check` / `./scripts/coverage` floor-free phase one; prefer library calls over test reimplementations; do not casually expand `exposed-modules` or weeder roots.

Locked program decisions relevant here: dedicated pure leftovers change first (T11-A); library-only HPC (T10-A); later waves own ProcessOps, Fake-HTTP, agents, and apply spine residual.

## Goals / Non-Goals

**Goals:**

- Raise Unit (and thus Overall) HPC expression/alt/bool coverage on pure and thin-IO leftover library surfaces by calling product functions.
- Keep the change small and apply-friendly (tests-first; no product redesign).
- Leave `./scripts/coverage` and `hk check` green without floors.

**Non-Goals:**

- ProcessOps, Fake-HTTP duals, SSH/GPG production adapters, apply/check/plan Integration residual
- Instrumenting or scoring cold `app/Main`
- Numeric floors / ratchet
- Product feature work or CLI UX changes
- Mandatory cleanup of large shared test import preambles

## Decisions

### D1: Unit-only isolation

**Choice:** All new cases go under the existing **Unit** tasty group.

**Alternatives:** Integration for config load (rejected—single-concern fixture/env I/O fits Unit).

**Rationale:** Matches `test-coverage` isolation rules; no apply/plan/commit spine.

### D2: Extend existing test modules

**Choice:** Add cases primarily to `Test.Config`, `Test.CLI`, `Test.Overlay`, `Test.Assets` (auth already present), and Types helpers either in `Test.Policy`/`Test.Overlay` or a tiny group in an existing pure-friendly module. Introduce a new `Test.*` module only if an existing file becomes unmaintainable.

**Rationale:** Follows suite layout; avoids suite restructure.

### D3: Config default path via `loadConfig Nothing` + env, not private export

**Choice:** `defaultConfigPath` is currently unexported. Heat it by calling `loadConfig Nothing` with controlled `XDG_CONFIG_HOME` / home-adjacent paths (or temporary config files), plus direct tests of `configErrorMessage` for `ConfigNotFound` and `DecodeError`.

**Alternatives:** Export `defaultConfigPath` solely for tests (only if env bracketing is too brittle at apply time).

**Rationale:** Prefer no export churn; fall back to minimal export if Unit cannot reach the XDG branch otherwise.

### D4: CLI residual via pure parser + careful exit for help

**Choice:**

- Extend pure `optparse-applicative` evaluation for remaining parse/verbosity/help-info edges without spawning the binary.
- For `showTopLevelHelpExit1`, exercise under Unit by catching `ExitCode` (or equivalent) if the function is designed to exit; assert non-success exit and that help was attempted—do not require full help prose match.

**Alternatives:** Black-box process CLI (out of scope / Main unscored).

**Rationale:** High residual heat without E2E suite.

### D5: Logging via `mkLogger` / hold API only

**Choice:** Call product `mkLogHold`, `mkLogger`, and hold/flush helpers with controlled verbosity/color; assert log filtering behavior at the product API, not by reimplementing severity maps already tested.

**Rationale:** Targets remaining yellow in `Logging.Bootstrap` without process spawn.

### D6: Overlay validation failure matrix with temp trees

**Choice:** Unit tests build temporary directories (or use/fix fixtures) to hit `NotADirectory`, `MissingDirectory`, `MissingFile`, and `RepoNameMismatch`. Prefer ad-hoc temp trees over editing committed fixtures when fixture content is wrong for the case (e.g. repo_name value).

**Rationale:** Exercises full `validateOverlay` error arms; avoids corrupting shared fixtures.

### D7: Auth and Types pure tables

**Choice:**

- Expand pure `resolveGitHubTokenWith` edges (whitespace-only tokens, strip, precedence) and optionally one `resolveGitHubToken` IO case with env bracket if easy.
- Table-drive `techniqueNeedsAssets`, `ecosystemIsGo|Npm|Bun|Cargo`, and `splitPackageKey` (valid `cat/pkg` and invalid/`Nothing` arms).

**Rationale:** Cheap expression and boolean heat on library helpers.

### D8: Success metric

**Choice:** Done when tasks are complete, Unit tests call the listed product surfaces, `./scripts/coverage` produces reports, and `hk check` passes. Overall percentage lift is **guidance only** (~+0.7–1.5 expr points expected); no floor enforcement.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| `defaultConfigPath` unexported | D3 env bracketing; export only if blocked |
| `showTopLevelHelpExit1` process/exit awkwardness | Catch ExitCode; skip full prose asserts; partial heat acceptable if exit path is hostile |
| Temp-tree races / leftover dirs | `bracket` / withSystemTempDirectory patterns already used in suite |
| Overlap with later Process/HTTP waves | Explicit non-goals; no production* adapters |
| HPC still yellow on help strings / dead literals | Accept residual; do not chase vanity |

## Migration Plan

1. Optional baseline note from existing `coverage/summary.json`.
2. Implement Unit cases per `tasks.md`.
3. Run `./scripts/coverage` and `hk check`.
4. Archive after green; next wave is `process-command-runner` (separate change).

Rollback: revert test (and any minimal export) commits.

## Open Questions

None blocking. Export of `defaultConfigPath` is an apply-time fallback under D3.
