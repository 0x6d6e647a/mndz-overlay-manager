## Context

Final maximization wave for residual dark surface after pure/builders/check-plan/materialize: SSH session lifecycle, GPG remaining branches, Git ops edges, Assets.Release HTTP, Http/Npm fetchers, and cheap alts elsewhere. Floors remain out of scope—this wave only raises the measured baseline.

## Goals / Non-Goals

**Goals:**

- Exercise residual modules with Unit and Integration as appropriate, using fakes.
- Improve boolean/alternative coverage on one-sided branches where cheap.
- Leave no large mockable module at single-digit % without justification.

**Non-Goals:**

- Numeric floors/ratchet (separate follow-up).
- Live pinentry, real SSH agent, live GitHub API in CI.
- Re-scoping Waves 1–4 work.
- Executable process E2E.

## Decisions

### D1: Fake at existing ops boundaries

**Choice:** Prefer `SshAgentOps`, `GitOps`, `ReleaseOps`, and HTTP try-helpers already designed for injection. Add minimal seams only when a residual function is unreachable without them—and only with a design note in tasks if product code must change.

### D2: Depth vs flakiness

**Choice:** Cover ensure/teardown/error messages and parse helpers thoroughly; do not require interactive TTY tests. GPG continues the existing fake-agent style from `Test.Gpg`.

### D3: Release HTTP

**Choice:** Fake at request/response boundary (injectable http actions or ops) for create/delete/download paths not hit by Materialize reuse tests. Pure `parseReleaseInfo` / `findAssetByName` already covered—do not retest only those.

### D4: Floors still phase-1

**Choice:** Explicitly do **not** implement floors here. After archive, a separate explore/propose uses post-wave `summary.json` for floor design.

### D5: Success metric

**Choice:** Residual targets no longer trivially dark where mockable; Overall horizon high 80s is guidance only; `./scripts/coverage` + `hk check` green.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Process-env tests flaky | Prefer pure parse + ops fakes; isolate env mutations |
| Encapsulation fights Release/Http tests | Same expose-or-ops pattern as Wave 1 |
| Diminishing returns | Stop when remaining uncov is production process wrappers with no seam—document in change notes |

## Migration Plan

1. Re-measure after Wave 4; adjust residual task list to actual dark modules.
2. Implement residual tests.
3. Final coverage + `hk check`.
4. Archive; open floors explore separately.

## Open Questions

- Exact residual list should be re-confirmed from a fresh `./scripts/coverage` after Wave 4 lands (tasks allow re-prioritization within Wave 5 scope).
