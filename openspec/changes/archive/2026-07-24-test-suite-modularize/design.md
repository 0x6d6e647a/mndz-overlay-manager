## Context

Part 7 of 8. `test/Main.hs` (~4412 LOC, ~102 tests) is a monolith with custom `assertEq` / `assertTrue`. Pure cores lack property tests. After renames and Apply split, modularizing tests is lower churn.

## Goals / Non-Goals

**Goals:**

- Domain-organized test modules + thin Main.
- Standard harness (tasty recommended) with clear pass/fail reporting.
- Preserve all existing scenario coverage (migrate, don’t drop).
- Add property tests for pure version/parse/engines cores.
- `cabal test all` remains the single gate entry.

**Non-Goals:**

- Live network/Portage integration suite.
- Mandatory coverage metrics.
- Rewriting scenario tests into properties.

## Decisions

### D1: Harness → tasty + tasty-hunit (+ tasty-quickcheck or hedgehog)

**Choice:** **tasty** as the runner; port assertions to HUnit-style or keep thin wrappers; add **tasty-quickcheck** *or* **hedgehog** for properties (prefer one; QuickCheck is enough for version laws).

**Rationale:** Mature, filterable (`tasty -p`), low ceremony for migrating IO tests.

**Alternatives:** hspec (also fine); stay custom (rejects the goal).

### D2: Module layout (illustrative)

```
test/Main.hs                 -- defaultMain tests
test/Test/Assert.hs          -- optional shared helpers during migration
test/Test/Overlay/Version.hs
test/Test/Overlay/Discovery.hs
test/Test/Config.hs
test/Test/Update/Apply.hs    -- or further split
test/Test/Update/Md5Cache.hs
test/Test/Update/Lanes.hs
test/Test/CLI/Progress.hs
test/Test/Update/Gpg.hs
...
```

Exact split can follow natural `test*` groups already in Main.

### D3: Migration strategy

**Choice:** Move tests in batches by domain; keep green after each batch. Do not change assertion *intent* while moving.

### D4: Property suite (minimum)

- Numeric `EbuildVersion` generator → `comparePV` reflexivity; antisymmetry when both `Just`.
- `renderPV . parse` round-trip for generated numeric versions (no raw).
- `parseEbuildFileName` for generated `pkg-ver.ebuild` shapes.
- Table-driven + property rejects for complex engines ranges.

### D5: Docs

**Choice:** Short CONTRIBUTING note on `cabal test all` and optional tasty pattern filter if contributor workflow benefits.

## Risks / Trade-offs

- **[Risk] Dependency / GHC bound issues for tasty** → Mitigation: pick versions compatible with GHC 9.10 / existing bounds; adjust cabal.project if needed.
- **[Risk] Flaky reordering of IO tests** → Mitigation: keep tests independent; avoid order dependence (already mostly independent).
- **[Risk] Incomplete migration leaves dead Main bulk** → Mitigation: tasks require Main thin and old monolith removed.

## Migration Plan

1. Add deps; skeleton Main with one moved test group.
2. Migrate remaining groups.
3. Add properties.
4. CONTRIBUTING if needed; `hk check`.

Rollback: restore single Main (git).

## Open Questions

- QuickCheck vs Hedgehog — default QuickCheck via tasty-quickcheck unless Hedgehog already preferred in ecosystem at apply time.
