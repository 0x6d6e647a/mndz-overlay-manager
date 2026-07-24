## 0. Prerequisites

- [x] 0.1 Prefer base after renames + Apply split (+ progress soft-skip if it still edits the monolith test file)

## 1. Harness skeleton

- [x] 1.1 Add tasty (+ tasty-hunit, and tasty-quickcheck or hedgehog) to the test-suite dependencies
- [x] 1.2 Create thin `test/Main.hs` with `defaultMain` and a first migrated test group
- [x] 1.3 Confirm `cabal test all` runs the new harness

## 2. Migrate scenario tests

- [x] 2.1 Split remaining tests into domain modules under `test/Test/...` (Overlay, Config, Apply, Md5, Progress, Gpg/Ssh, Lanes/Plan, etc.)
- [x] 2.2 Preserve assertion intent; no silent drops
- [x] 2.3 Remove the old monolith bulk once empty

## 3. Property tests

- [x] 3.1 Properties for numeric `comparePV` laws
- [x] 3.2 Round-trip properties for numeric `parseEbuildVersion` / `renderPV`
- [x] 3.3 Properties or generators for well-formed `parseEbuildFileName`
- [x] 3.4 Engines minimum accept/reject coverage (table + optional properties)

## 4. Docs and verify

- [x] 4.1 Update `CONTRIBUTING.md` for full test run and optional tasty filter
- [x] 4.2 `cabal test all` and `hk check` green
- [x] 4.3 Sync `project-docs` delta at archive
- [x] 4.4 Next: `quality-tooling-tighten`
