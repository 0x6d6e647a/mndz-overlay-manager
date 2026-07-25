## Context

`Update.Npm.Cache`, `Update.Bun.Cache`, and `Update.Cargo.Crates` are ~0% HPC expression coverage while production uses them for DepsAndAssets. Injectable `*Ops` records already exist (`production*` wires process steps). Wave 2 exercises pure helpers and builders with fakes for **npm, bun, and cargo equally**.

## Goals / Non-Goals

**Goals:**

- Drive pure eco helpers and `build*Tarball` (or equivalent) success/failure/progress under Unit.
- Light Integration only when multi-module wiring is the natural assertion (not full Materialize apply—Wave 4).
- Leave zero-modules for these three builders.

**Non-Goals:**

- `planDepsPackageWithProgress` full spine (Wave 3), Materialize apply (Wave 4), live network, floors.

## Decisions

### D1: Equal ecosystem treatment

**Choice:** Task list and suite groups cover **npm, bun, and cargo** in the same change with analogous cases (pure gate + builder success + builder fail at minimum each).

**Rationale:** Product decision—all equally critical; avoids Go-only bias.

### D2: Fake Ops, not production processes

**Choice:** Construct `NpmCacheOps` / `BunCacheOps` / `CargoOps` with in-memory or temp-dir fakes that write a dummy tarball / return controlled errors. Do not invoke real `npm`/`bun`/`cargo` in CI for this wave unless a pure-ish host version probe is already free of network.

**Rationale:** Stable gate; matches Go vendor/mod test style.

### D3: Progress callbacks

**Choice:** Where builders accept progress records, assert ordered or presence-of-key progress events (lightweight), not full panel UI.

**Rationale:** Covers more expressions without duplicating `Test.Progress` host tests.

### D4: Test module layout

**Choice:** Prefer a dedicated module (e.g. `Test.Ecosystems` or per-eco modules) over appending everything to `Test.Apply` / `Test.Lanes`.

**Rationale:** Apply is already very large; Wave 4 will grow apply further.

### D5: Success metric

**Choice:** Done when three builder modules are no longer 0% expr, tasks green, `./scripts/coverage` + `hk check` pass. Horizon ~62–65% Overall is guidance only.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Ops API incomplete for pure unit testing | Extend fakes only; avoid product redesign unless a one-line seam is required |
| Accidental live network | Never construct production managers for registry calls in these tests |
| Partial builder coverage still large | Wave 3/4 continue; Wave 2 goal is exit zero, not 100% |

## Migration Plan

1. Confirm Wave 1 archived or explicitly skipped with baseline note.
2. Implement pure + builder fakes per eco.
3. Coverage + `hk check`.
4. Archive; Wave 3 next.

## Open Questions

None blocking.
