## 1. Multi-PV unit ordering

- [x] 1.1 In `Update.Apply.Materialize.materializeDepsPlan` (or a pure helper next to it), order planned units that need work: **missing** PVs first, then pure **content-fix** PVs; within each group sort by ascending PV (same comparison as today’s numeric sort)
- [x] 1.2 Classify “missing” as no local non-live same-PV ebuild (`missingTargets` / equivalent); a PV that is missing is ordered as missing even if also content-related
- [x] 1.3 Add unit tests covering: missing newer PV before content-fix of older local PV; content-fix-only multi-PV keeps ascending PV order

## 2. Missing template hard-fail

- [x] 2.1 After `findTemplate` (and before `TIO.readFile` in `overlayAfterAssets`), hard-fail the unit if the template path does not exist, with an actionable message (package / planned PV / path)
- [x] 2.2 Align other donor/template ebuild reads that share the same pattern (e.g. cargo `findTemplate` + `readFile` in Materialize) so they hard-fail instead of throwing uncaught `openFile`
- [x] 2.3 Optionally extend `ApplyUnitError` (or equivalent) so the missing-donor class is consistent with other identifiable hard-fails; ensure operator message is non-empty and identifiable
- [x] 2.4 Add a test that a missing template path yields `ApplyHardFail` (or equivalent) without an uncaught IOException

## 3. Quality and validation

- [x] 3.1 Run `openspec validate deps-assets-multipv-unit-order --strict` and fix any artifact issues
- [x] 3.2 Run `hk check` (or full CONTRIBUTING pipeline) and fix failures
- [x] 3.3 Confirm no README/CONTRIBUTING/AGENTS update is required; if hard-fail recovery text is documented there, update in this change per `project-docs`
