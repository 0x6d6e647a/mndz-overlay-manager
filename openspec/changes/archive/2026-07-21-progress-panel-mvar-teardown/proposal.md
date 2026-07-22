## Why

Rarely, `outdated` (and the same multi/step progress hosts used by `update`) dies with `thread blocked indefinitely in an MVar operation` right after the progress panel appears. The failure is flaky and independent of package logic: a background redraw thread can abandon or never signal teardown, leaving the main thread blocked on an empty `doneVar` while holding no path forward. Operators should never hang the CLI on best-effort activity chrome.

## What Changes

- Harden multi-progress and sequential step-bar hosts in `CLI.Progress` so the draw mutex is exception-safe (no abandoned `drawLock` on throw during render/emit/clear/pause/resume).
- Replace the `forkIO` + empty `stopVar`/`doneVar` join with structured panel lifetime (**B2**): `withAsync`, cooperative stop, short grace wait, then `cancel` if the panel does not exit.
- Drop reliance on a one-shot `doneVar` put that can never fire if the panel self-deadlocks.
- Add deterministic no-hang tests (injectable draw/clear seam) covering draw failures, action failures, and pause/clear failures for both multi and step panels.
- Panel failure or cancel after a successful action SHALL NOT fail the command; chrome remains best-effort.
- No product/UX changes to bars, jobs, flags, or log-hold ordering beyond safer teardown before flush.

## Capabilities

### New Capabilities

<!-- None — reliability of existing activity indicators only. -->

### Modified Capabilities

- `cli-activity`: Require reliable panel teardown (exception-safe draw mutex; structured panel lifetime with cooperative stop and cancel-after-grace) so host exit cannot block indefinitely on progress-internal MVars, and so redraw/clear failures do not prevent deferred logs and machine stdout after the phase body finishes.

## Impact

- **Code**: `src/CLI/Progress.hs` (multi + step hosts, pause/resume); tests under `test/` (progress host no-hang cases). Callers (`app/Main.hs`, `Update.Apply`) keep the same `withMultiProgress` / `withStepProgress` API unless a small internal test seam is exported or package-private.
- **Dependencies**: Prefer existing `async` (already used by `CLI.Jobs`); no new packages expected.
- **Out of scope**: `CLI.Jobs` package pool, Apply overlay/assets locks, Go planning caches, GPG/SSH brackets, logging redesign, new CLI flags, `--no-progress` semantics (unchanged).
- **Ops**: No config or overlay format changes; TTY smoke of `outdated` / preflight step bar after implement.
