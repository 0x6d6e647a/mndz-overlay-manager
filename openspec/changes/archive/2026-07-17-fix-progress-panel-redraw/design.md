## Context

Activity indicators live in `CLI.Progress`. Multi-progress and sequential step bars share a background redraw loop that:

1. Renders a frame string via layoutz widgets (`inlineBar`, `spinner`, `layout`).
2. Calls `drawFrame` to move the cursor up by a stored line count, rewrite lines, and clear extras when the new frame is shorter.
3. Stores `length (lines frame)` as the next move-up distance.

`clearLines` (used on panel pause and teardown) correctly moves up, clears, then moves up again so the cursor returns to the panel origin. `drawFrame` on **shrink** writes pad clear-lines for the old height but leaves the cursor at the bottom of that taller band while storing only the **new** shorter height. The next tick moves up too few lines; previous top-bar frames remain as ghosts. This is most visible on `outdated` as stacked `Checking packages k/N …` lines while concurrent jobs finish and rows disappear.

Constraints: keep stderr-only chrome, log hold, `withUiSuspended` / GPG pause, `MultiHandle` / `StepHandle` APIs, and machine stdout deferred until after clear. No new dependencies.

## Goals / Non-Goals

**Goals:**

- Restore the invariant: after every redraw, cursor distance from panel top equals the stored owned height, and that height equals the logical content line count for the live panel (dynamic height).
- Unit-test pure draw planning for grow, shrink, same height, first frame, and empty/clear-shaped cases.
- Share one correct writer for multi-progress and step bars.
- Preserve existing UX: success removes rows (panel may shrink); fail/soft-skip rows remain until phase clear.

**Non-Goals:**

- Stable-height / watermark padding as a product mode (optional later on the same planner).
- Soft-wrap / terminal-width physical-line accounting.
- Replacing the host with layoutz `runInline` (follow-on `layoutz-progress-host`).
- Changing progress labels, colors, job concurrency, or report formats.

## Decisions

### 1. Tight dynamic height (Option A), not stable reserve

**Choice:** After writing content and any clear-extra lines for the previous taller band, **move the cursor back up** by `(prev - n)` when `prev > n`, then store `n = length contentLines`.

**Rationale:** Matches success-removes-row UX and fail-row accumulation without over-reserving `1 + total` blank lines. Aligns `drawFrame` with the move-back pattern already used in `clearLines`.

**Alternatives:**

- Fixed reserve `1 + jobs` — wrong when fail rows accumulate beyond jobs.
- Fixed reserve `1 + total` — correct but sparse and tall.
- Grow-only watermark (never reclaim mid-run) — valid UX mode; defer; can be a one-line policy on the same planner later.
- layoutz runtime host — separate experiment after this fix.

### 2. Pure `planDraw` (or equivalent) then thin ANSI emit

**Choice:** Extract pure planning from `prevLineCount` + frame string into a structure: move-up count, content lines, clear-extra count, move-back count, store count. `drawFrame` only emits ANSI and flushes.

**Rationale:** Shrink bugs are pure math; TTY tests are flaky. Fixture tests lock the invariant without a terminal.

**Alternatives:** Only fix emit in place without pure layer — smaller diff but easy to regress and hard to test.

### 3. Logical newlines remain the unit of height

**Choice:** Continue counting `lines frame` as panel height (layoutz logical lines).

**Rationale:** Sufficient for the reported bug (top bar short; shrink desync). Soft-wrap remains a known residual risk for long package rows; out of scope.

### 4. Shared fix for multi and step loops

**Choice:** Fix only the shared writer/store path; do not fork separate geometry for step bars.

**Rationale:** Step bars are usually height 1 but use the same `drawFrame` / `lineCountRef` pattern; one fix covers both.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Regress move-back / store again in a “cleanup” | Pure plan tests for shrink and empty |
| Incomplete clear on exit if store still wrong | Same invariant; cleanup already uses `lineCountRef` |
| Soft-wrap still desyncs on narrow terminals | Document residual; optional later width clamp |
| Child process stderr mid-panel still garbles | Pre-existing; log hold + process capture best-effort only |
| Double CUU on shrink flickers | Negligible at ~80ms tick rate |

## Migration Plan

1. Land pure planner + `drawFrame` emit + tests.
2. Manual smoke: TTY `outdated` (and optional `update`); confirm single live panel and clean teardown.
3. No data migration; no flag changes.
4. Rollback: revert the Progress.hs change; behavior returns to stacked lines.

## Open Questions

None blocking. Optional later: watermark height policy as a flag on the planner; terminal-width truncation for package rows.
