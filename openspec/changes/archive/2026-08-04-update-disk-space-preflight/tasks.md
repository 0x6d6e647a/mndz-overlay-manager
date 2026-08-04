## 1. Core pure estimates and free-space plumbing

- [x] 1.1 Add `Update.DiskSpace` (or equivalent) with named constants: ecosystem expansion factors, floors, fixed **256 MiB** margin
- [x] 1.2 Implement pure helpers: need from baseline×factor+margin, max need, concurrent sum of top-N unit needs, same-device merge of path needs
- [x] 1.3 Implement injectable `getFreeBytes` / device identity over `statvfs` (production + test fakes)
- [x] 1.4 Parse Manifest `DIST <name> <size> …` for baseline size by asset class; unit-test parser
- [x] 1.5 Extend `ReleaseAsset` with optional/required `size`; parse GitHub release JSON `size`; update tests for release parse/lookup

## 2. Gate orchestration

- [x] 2.1 Resolve effective temp root (`TMPDIR` / default), manager distfiles path, live Portage DISTDIR
- [x] 2.2 Build per-unit need plans (temp full/reuse/floor; manager DISTDIR missing distfiles only; present files → 0)
- [x] 2.3 Run command-level feasibility: hard-fail with path, free, need, and hints (`TMPDIR`, free space, `--jobs`) when free &lt; max or free &lt; concurrent sum
- [x] 2.4 Emit warn-only when Portage DISTDIR is distinct and free space is tight
- [x] 2.5 Wire gate into `update` spine after tools/assets/distfiles probe and before concurrent package mutation; include preflight progress step when activity enabled

## 3. Apply-time rechecks

- [x] 3.1 At full-path materialize admit, re-measure temp free space and hard-fail the unit if below that unit’s temp need
- [x] 3.2 After clone on full path, measure work tree when cheap; hard-fail unit if measured + remaining estimate exceeds free; skip cleanly if measurement unavailable

## 4. Tests

- [x] 4.1 Unit tests: margin, factors, floors, max vs concurrent sum under N=1 and N=2, same-device combined budget
- [x] 4.2 Unit tests: gate fails/passes with injected free bytes; Portage warn does not hard-fail
- [x] 4.3 Unit tests: GH asset size parse; Manifest DIST size parse; present distfile → zero DISTDIR need
- [x] 4.4 Extend preflight/Main-related tests if spine step count or failure paths change

## 5. Docs and quality

- [x] 5.1 Update `README.md` for TMPDIR, free-space gate, estimate basis, remediation, Portage warn-only (project-docs)
- [x] 5.2 Register module in cabal (`other-modules` unless export required); avoid casual `exposed-modules` / weeder root expansion
- [x] 5.3 Run `openspec validate update-disk-space-preflight --strict` (or project-equivalent) and fix artifact issues
- [x] 5.4 Run full `hk check` and fix all failures before marking complete
