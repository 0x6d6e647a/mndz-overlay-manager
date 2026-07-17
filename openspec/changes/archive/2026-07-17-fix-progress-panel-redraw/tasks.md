## 1. Pure draw plan

- [x] 1.1 Extract pure `planDraw` (or equivalent) from `prevLineCount` + frame string: move-up, content lines, clear-extra, move-back, store count
- [x] 1.2 Unit tests: first frame, grow, same height, shrink, empty/clear-shaped—assert store equals content line count and move-back equals max(0, prev − n)
- [x] 1.3 Export pure planner only as needed for tests; keep implementation in `CLI.Progress`

## 2. Wire emit path

- [x] 2.1 Rewrite `drawFrame` to emit ANSI solely from the pure plan (content + EL + LF, clear extras, move-back on shrink)
- [x] 2.2 Confirm multi-progress and step-bar loops still store the plan’s store count after each draw
- [x] 2.3 Confirm `clearLines` / pause / cleanup still clear the owned band (no change required if store stays correct)

## 3. Verify

- [x] 3.1 `cabal test all` (or project test entry) green including new planner tests
- [x] 3.2 `hk check` (or full quality gate per AGENTS.md) green
- [x] 3.3 Manual TTY smoke: `outdated` shows one living “Checking packages” panel without stacked history; after exit, report lines with no leftover intermediate bars
