## Context

`Update.Apply.Materialize` is the largest uncov absolute. Integration apply tests cover Go full/reuse/git-mv heavily; npm/bun/cargo branches in `applyDepsAndAssets` / materialize step accounting remain cold. Waves 2–3 should have supplied eco builder and plan fakes.

## Goals / Non-Goals

**Goals:**

- Unit + Integration coverage of Materialize/apply deps-and-assets for **npm, bun, cargo** (and Go residual gaps).
- Reuse `ApplyEnv`, mock egencache, `ReleaseOps`, progress sequence assertions from existing Go tests.
- Drop Materialize uncov substantially without live network.

**Non-Goals:**

- Agent/Git/Release residual program (Wave 5), floors, executable E2E, product behavior changes.

## Decisions

### D1: Mirror Go apply test shape per eco

**Choice:** For each of npm/bun/cargo, add at least:

1. **Integration:** successful materialize path with mocked ops (temp overlay, commit/egencache fakes as needed).
2. **Integration or Unit:** one hard-fail or soft-skip path product already defines.
3. Where reuse exists for that eco, a reuse-path sequence test analogous to Go reuse.

**Rationale:** Equal treatment; proven harness in `Test.Apply`.

### D2: Test module growth strategy

**Choice:** Prefer `Test.Apply` split helpers or `Test.Materialize` module if `Test.Apply` would exceed maintainability; keep `unitTests` / `integrationTests` exports for Main wiring.

**Rationale:** Apply file already ~1.6k lines.

### D3: Progress assertions

**Choice:** Reuse event-order / step-budget style tests for multi-eco materialize step totals where expressions live in Materialize.

### D4: Success metric

**Choice:** Materialize expression coverage moves well above ~40%; Overall horizon ~80% guidance only; gates green.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Eco apply path incomplete product support | Test real branches only; do not invent product features to gain coverage |
| Flaky temp git | Follow existing commit-lock / mock patterns that already pass under HPC |
| Wave 2/3 fakes insufficient | Extend fakes in this change only as needed for apply |

## Migration Plan

1. Confirm builder/plan fakes available from prior waves.
2. Implement per-eco materialize tests.
3. Coverage + `hk check`.
4. Archive; Wave 5 residual.

## Open Questions

None blocking.
