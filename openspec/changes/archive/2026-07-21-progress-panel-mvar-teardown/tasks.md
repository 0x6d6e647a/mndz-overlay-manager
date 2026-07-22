## 1. Draw mutex and test seam

- [x] 1.1 Add exception-safe draw lock helper (`withMVar` / `withDrawLock`) in `CLI.Progress`
- [x] 1.2 Use the helper for multi/step tick redraw, final clear, `pausePanel`, and `resumePanel` (no bare take/put on `drawLock`)
- [x] 1.3 Add injectable panel IO seam for draw/clear (and delay if useful); production defaults remain `drawFrame` / `clearLines` / `threadDelay`
- [x] 1.4 Keep public `withMultiProgress` / `withStepProgress` / pause-resume APIs stable for Main and Apply

## 2. B2 panel lifetime

- [x] 2.1 Replace multi-progress `forkIO` + `doneVar` join with `withAsync`, cooperative stop, grace wait (`race` + `waitCatch`), then `cancel` + reap
- [x] 2.2 Apply the same B2 teardown pattern to sequential step-bar host
- [x] 2.3 Choose a fixed grace constant in 200–500ms (e.g. 300ms); no CLI flag
- [x] 2.4 On panel failure/cancel after successful body: still clear controller, flush log hold, return body result (do not fail the command for chrome alone)
- [x] 2.5 Remove unused `doneVar` / dead join code paths

## 3. Tests

- [x] 3.1 Multi-progress: draw/clear throws under lock → host returns within a short race bound after body finishes
- [x] 3.2 Multi-progress: phase body throws → exception propagates and host tears down without hang
- [x] 3.3 Multi-progress: successful body + panel failure/cancel path still returns success and completes teardown
- [x] 3.4 Step-progress: same three no-hang contracts as 3.1–3.3
- [x] 3.5 Pause/resume: clear or resume critical section throws → draw lock not permanently stuck; subsequent panel use/teardown OK
- [x] 3.6 Existing pure progress tests (`planDraw` / render) still pass

## 4. Verification

- [x] 4.1 Run project quality gate (`hk check` or equivalent full pipeline per CONTRIBUTING)
- [x] 4.2 Manual TTY smoke: `outdated` with progress; optional `update` preflight step bar
