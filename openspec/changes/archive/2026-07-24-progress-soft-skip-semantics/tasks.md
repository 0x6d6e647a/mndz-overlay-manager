## 0. Prerequisites

- [x] 0.1 Prefer base that includes `split-apply-module` so Apply tracking lives in a clear home

## 1. MultiHandle and render

- [x] 1.1 Add `mhSkip` (or equivalent) to `MultiHandle` and `noopMultiHandle`
- [x] 1.2 Extend pure multi-progress state + `renderMulti` with a distinct skip terminal presentation (glyph/styling ≠ hard-fail when color on)
- [x] 1.3 Keep success row removal and phase clear semantics unchanged

## 2. Apply wiring

- [x] 2.1 Soft-skip-only package outcomes call skip path, not `mhFail`
- [x] 2.2 Hard-fail still uses fail path; success unchanged
- [x] 2.3 Confirm `foldExitHardFail` / process exit policy unchanged

## 3. Tests and specs

- [x] 3.1 Update/add progress pure tests for skip vs fail chrome
- [x] 3.2 Update apply tracking tests if they assert terminal handle calls
- [x] 3.3 Delta `cli-activity` already drafted; keep it aligned with implementation
- [x] 3.4 `cabal test all` and `hk check`

## 4. Program handoff

- [x] 4.1 Sync `cli-activity` into main specs at archive
- [x] 4.2 Next: `test-suite-modularize` (if not started), then `quality-tooling-tighten`
