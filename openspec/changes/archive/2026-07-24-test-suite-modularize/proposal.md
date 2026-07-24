## Why

The test suite is a single ~4.4k-line `test/Main.hs` with a hand-rolled runner. It is thorough but hard to navigate, filter, and own. Pure cores (`comparePV`, version parse, ebuild filename parse, engines minimum) lack property-based coverage, so refactors rely only on example tests.

## What Changes

- Split tests into domain modules under `test/` (e.g. Overlay, Apply, Progress, Md5Cache, Gpg/Ssh, Lanes/Plan) with a thin `Main` runner.
- Introduce a standard harness (**tasty** + HUnit-style cases, or hspec) so suites can be selected and reported clearly.
- Migrate existing scenario tests without dropping coverage — rehome, do not rewrite business assertions.
- Add property-based tests for pure invariants:
  - numeric `comparePV` laws (reflexivity, antisymmetry/transitivity where defined)
  - `parseEbuildVersion` / `renderPV` round-trip for generated numeric PVs
  - well-formed `parseEbuildFileName`
  - `parseEnginesMinimum` accept/reject tables
- Update cabal test-suite stanza for new modules and dependencies.
- Document how to run the full suite (and optionally a subset) in CONTRIBUTING if contributor workflow text changes.

## Program context

- **Part 7 of 8** of the post-audit quality program.
- **Apply order:** after renames and Apply split so test module paths do not move twice; after or alongside progress soft-skip if that change still touches `test/Main.hs`.
- **Depends on:** `runtime-naming-cleanup`, `split-apply-module` (recommended); better after parts 4–6 if those still edit the monolith test file.

## Non-goals

- Live integration tests against real GitHub/Portage networks.
- Coverage percentage mandates or CI browser reports.
- Replacing ops-fake scenario tests with only properties.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `project-docs`: CONTRIBUTING documents full test run and optional harness filter for modular tasty (or equivalent) suite.

## Impact

- **Code:** `test/**`, `mndz-overlay-manager.cabal` test-suite deps (tasty/quickcheck or hedgehog).
- **CI/local:** `cabal test all` remains the gate; must stay green.
- **Docs:** CONTRIBUTING when describing the new layout.
