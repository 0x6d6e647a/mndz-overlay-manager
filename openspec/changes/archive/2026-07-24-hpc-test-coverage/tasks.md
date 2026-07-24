## 1. Test taxonomy (Unit / Integration)

- [x] 1.1 Document the Unit vs Integration classification rule in a short comment or CONTRIBUTING subsection (aligned with design D3)
- [x] 1.2 Classify every existing tasty test module / testCase under Unit or Integration
- [x] 1.3 Restructure `test/Main.hs` (and module `tests` exports if needed) so top-level groups are `Unit` and `Integration`, with property tests under Unit
- [x] 1.4 Verify `cabal test all` still passes with the new tree and tasty patterns can select Unit vs Integration (e.g. `-p Unit`)

## 2. Coverage runner and artifacts

- [x] 2.1 Add `scripts/coverage` (or equivalent) that runs `cabal test all --enable-coverage`, locates `.tix`/mix data, and fails clearly if artifacts are missing
- [x] 2.2 Generate Overall report from the full suite (expressions, alternatives, booleans) via `hpc report` / XML or equivalent
- [x] 2.3 Generate Unit and Integration attribution reports (filtered suite runs and/or combined tix) into the same summary shape
- [x] 2.4 Produce HTML markup under a documented output directory (e.g. `coverage/html/`)
- [x] 2.5 Produce machine-readable summary (e.g. `coverage/summary.json`) including Overall, Unit, and Integration rows
- [x] 2.6 Exclude `Update.Apply.TestSupport` (and document any other scaffolding excludes) from the product denominator
- [x] 2.7 Gitignore coverage output directory / ephemeral tix patterns; do not commit HTML or baseline floors

## 3. Quality pipeline (hk)

- [x] 3.1 Update `hk.pkl` so the pipeline runs non-coverage `cabal build all` then the coverage entrypoint as the blocking test step (before hlint/stan/weeder)
- [x] 3.2 Ensure pre-commit and `hk check` share the coverage step; `hk fix` remains preflight + ormolu only
- [x] 3.3 Confirm stan/weeder still use `.hie/{lib,exe,test}/` from the non-coverage build

## 4. Documentation

- [x] 4.1 Update `CONTRIBUTING.md` pipeline table and day-to-day commands for build + coverage entrypoint, report locations, and Unit/Integration meaning
- [x] 4.2 Update `AGENTS.md` only if preferred gate commands need a thin pointer change (keep AGENTS thin)
- [x] 4.3 Note that numeric floors/ratchet are intentionally not enforced yet

## 5. Verification

- [x] 5.1 Run the coverage entrypoint successfully and inspect Overall/Unit/Integration summary numbers
- [x] 5.2 Run full `hk check` green with the new pipeline
- [x] 5.3 Confirm coverage artifacts are gitignored and not staged
- [x] 5.4 Archive readiness: `openspec validate` (or project equivalent) for this change if used before merge
