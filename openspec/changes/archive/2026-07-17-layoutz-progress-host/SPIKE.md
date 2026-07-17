# Spike notes — layoutz-progress-host

Library under test: **layoutz 0.3.4.0** (project pin `layoutz ^>=0.3.4`), source inspected from Hackage tarball (`Layoutz.hs`).

## 0. Prerequisite (task 0.1)

**Status: satisfied.**

- Change `fix-progress-panel-redraw` is archived at `openspec/changes/archive/2026-07-17-fix-progress-panel-redraw/`.
- HEAD includes `95e1fc2 fix: redraw multi-progress panels in place on shrink`.
- `CLI.Progress.planDraw` / `drawFrame` implement tight dynamic height with `dpMoveBack` on shrink (post-A geometry).

Interactive TTY re-smoke of `outdated` was not re-run in this session; code and archive tasks are the oracle that A is applied.

## 0.2 Post-A baseline (parity checklist)

External surface to preserve if C were kept:

| Concern | Post-A location / contract |
|--------|----------------------------|
| Enablement | `progressEnabled`: stderr TTY and not `--no-progress`; `pcEnabled` gates panels |
| Chrome handle | `pcHandle = stderr` only |
| Multi API | `MultiHandle`: `mhStart`, `mhStatus`, `mhSteps`, `mhStep`, `mhSuccess`, `mhFail` |
| Step API | `StepHandle`: `shStep` |
| Host model | Background tick loop (~80ms); workers mutate `IORef` state; loop owns redraw |
| Frame geometry | Pure `planDraw` → `drawFrame` (move-up, rewrite + EL, clear-extra, **move-back**, store height) |
| Pause | `PanelController` via `pcPanelCtrl`; `pausePanel` clears lines + sets paused; `resumePanel` clears pause flag; next tick redraws |
| GPG | `withUiSuspended` / `pauseActivePanel`+`resumeActivePanel` wired from Main into GpgAgent ops |
| Log hold | `beginLogHold` on panel enter; `flushLogHold` after panel clear on exit |
| Deferred machine stdout | Callers print package results after `withMultiProgress` / step panels return (post clear) |
| Content pure | `renderMulti` / multi-state tests define **what** to show |

## 1.1 Pause / clear / resume spike (`runInline` / `runAppWithFinal`)

**Result: no clean path for our process model.**

`runInline` is:

```haskell
runInline app = runAppWithFinal defaultAppOptions
  { optClearOnStart = False, optClearOnExit = False } app >> pure ()
```

Observed constraints in `runAppWithFinal` (0.3.4.0):

1. **Owns stdin for the lifetime of the run** — raw mode, no echo, blocking `inputLoop` until exit / ESC / Ctrl+C / Ctrl+D.
2. **No pause/resume API** — no public way to stop the render thread, clear the panel region, yield the TTY to pinentry, then resume the same app instance.
3. **No external message injection** — messages only from keyboard handlers, tick subs, and `Cmd` results. Concurrent package workers cannot enqueue into the runtime without redesigning Check/Apply around Elm `Cmd` (explicit non-goal).
4. **Blocking host** — `runInline` does not return until `CmdExit`. Our model runs workers on the calling thread while a side loop paints. Inverting that is a process-model rewrite, not a thin host swap.
5. **Inline shrink geometry still lacks move-back** — render thread:

   ```text
   moveUp ++ content lines ++ clear-extra pad lines
   ```

   with no cursor move-back after pad clears (same class of bug A fixed). Using the stock host would reintroduce stacked frames under success-removes-row.

A minimal “show panel → clear → blocking read → re-show” path would require either:

- forking/killing whole `runAppWithFinal` sessions around each pinentry (teardown half the UI model; race-prone; still stdout), or
- reimplementing a host ourselves and only using layoutz widgets (status quo).

Neither meets “layoutz owns multi-line frame geometry” with clean GPG yield.

## 1.2 Stderr placement

**Result: blocking limitation.**

All runtime I/O in `runAppWithFinal` uses `putStr` / `hFlush stdout` / `hSetBuffering stdout`. There is **no** `AppOptions` (or other) field to select a `Handle`. Indicator chrome cannot stay on stderr without forking layoutz or wrapping process FDs globally (unacceptable for machine stdout contracts).

Cursor hide/show and terminal-width probe also go through stdout/stdin.

## 1.3 Go / no-go

**Decision: REJECT experiment C.** Keep post-A hand-rolled host.

Kill criteria hit (from design):

| Criterion | Outcome |
|-----------|---------|
| Pause/resume for GPG clean | **Fail** — no pause API; stdin hijack; would need tear down / process-model rewrite |
| stderr-only chrome | **Fail** — hardcoded stdout |
| Worker bridge thin (Progress-local) | **Fail** without redesigning Check/Apply into Cmd |
| Net reduction of project-owned multi-line ANSI | **Fail** — would still need custom host for stderr + pause; stock host even lacks A’s shrink fix |
| Ghost lines / stdout pollution | Stock host risks both |

Host swap tasks (2.x) and parity implementation tasks (3.1–3.3) are **cancelled** as not applicable after reject. Task 3.4 records the keep-post-A decision.

## Follow-ups (not in scope)

- If layoutz gains: configurable output `Handle`, external mailbox for msgs, and pause/clear/resume that yields stdin, re-open an experiment.
- Optionally upstream: shrink move-back for inline mode (same fix as A).
- Product remains on layoutz **widgets** only (`inlineBar`, `spinner`, `layout`, colors) — unchanged.
