## Context

`CLI.Progress` hosts multi-progress (`withMultiProgress`) and sequential step bars (`withStepProgress`). Both:

1. `forkIO` a redraw loop (~80ms tick).
2. Join via empty MVars: main `putMVar stopVar` then `takeMVar doneVar`; panel `finally` takes `drawLock`, clears lines, `putMVar doneVar`.
3. Guard redraw/pause/resume with a manual `takeMVar`/`putMVar` on `drawLock` (not `withMVar` / `bracket`).

If anything throws between taking and putting `drawLock` (render, ANSI emit, clear on pause), the panel’s `finally` re-enters `takeMVar drawLock` and self-deadlocks. Main then blocks forever on `doneVar`. GHC reports `thread blocked indefinitely in an MVar operation`. The flake is rare (once observed in production use) and independent of package check correctness; `--no-progress` bypasses the host.

Scope is **only** this progress host reliability. Package jobs (`CLI.Jobs`), Apply locks, Go caches, and GPG/SSH brackets are out of scope.

## Goals / Non-Goals

**Goals:**

- Exception-safe draw mutex so redraw/clear/pause/resume cannot abandon `drawLock`.
- Structured panel lifetime (**B2**): `withAsync`, cooperative stop, grace wait, then `cancel` if the panel does not exit.
- Teardown that cannot leave the command blocked indefinitely on progress-internal MVars after the phase body finishes (success or exception).
- Panel chrome remains best-effort: panel failure/cancel after a successful action does not fail the command.
- Preserve existing UX: multi/step presentation, log hold begin/flush order (clear panel then flush), pause/resume for GPG via `PanelController`.
- Deterministic no-hang tests via injectable draw/clear (no TTY required).

**Non-Goals:**

- Changing package job pools, work budget, Apply/GPG/SSH concurrency, or Go planning caches.
- New CLI flags, grace-timeout knobs, or progress look-and-feel.
- Guaranteeing perfect TTY recovery if cancel interrupts mid-ANSI (best-effort clear).
- Replacing layoutz widgets or redraw geometry (`planDraw` stays).

## Decisions

### 1. Exception-safe draw mutex (mandatory)

**Choice:** Every critical section that currently does bare `takeMVar drawLock` / `putMVar drawLock` uses `withMVar` (or equivalent `bracket`). Shared helper, e.g. `withDrawLock :: MVar () -> IO a -> IO a`.

Apply to: multi tick draw path, step tick draw path, pause clear, resume flag flip, final panel clear in panel `finally`.

**Rationale:** Removes the self-deadlock class that matches the observed exception. Primary fix; handshake changes alone do not fix abandoned lock.

**Alternatives:** Masked take/put by hand (easy to regress); STM TVar lock (unnecessary churn).

### 2. Panel lifetime B2: `withAsync` + stop + grace + cancel

**Choice:** Replace `forkIO` + `doneVar` with:

```
withAsync (panelLoop stop …) $ \panel ->
  action handle `finally` do
    signal stop                    -- cooperative (MVar or IORef/TMVar flag)
    raced <- race (waitCatch panel) (threadDelay graceMicros)
    case raced of
      Right _ -> pure ()           -- panel exited (ok or exception)
      Left () -> do
        cancel panel
        void (waitCatch panel)     -- reap
    clear PanelController ref
    flushLogHold …
```

- No `doneVar`.
- Grace constant in code (recommend **200–500ms**; pick one, e.g. `300_000` µs). Not user-configurable in this change.
- Prefer `waitCatch` over bare `wait` so panel exceptions do not escape and kill a successful action.
- Log panel failure at most at debug (optional; not required for product stdout contracts).

**Rationale:** Structured join is the natural expression of “parent owns chrome thread.” Cancel after grace is belt-and-suspenders if cooperative stop is ignored or the thread is wedged outside the lock (e.g. uninterruptible only in rare cases; cancel still best-effort).

**Alternatives considered:**

| Option | Why not chosen |
|--------|----------------|
| A: keep `forkIO` + `tryPutMVar doneVar` | Smaller diff but retains ad-hoc protocol; weaker exception observability |
| A′: A + timeout on `take doneVar` | Policy timeout without structured cancel; still two empty MVars |
| B1: `withAsync` + wait only | Cleaner than A but can still hang if panel never exits after stop |
| **B2 (chosen)** | Cooperative stop + cancel-after-grace |

### 3. Stop signal

**Choice:** Keep a single cooperative stop channel (empty `MVar ()` with `put`/`tryPut` + `tryTake` in the loop, or an `IORef Bool` / `TMVar`). Prefer the simplest correct form: `MVar ()` stop with `tryPutMVar` from teardown and `tryTakeMVar` (or `isEmptyMVar` + take) in the tick loop—same as today for stop, without `doneVar`.

**Rationale:** Minimal behavioral change for the loop; only the join side moves to `async`.

### 4. Test seam for draw/clear

**Choice:** Internal injectable IO for draw and clear (and optionally delay), defaulting to production `drawFrame` / `clearLines` / `threadDelay`. Expose only what tests need (package-visible helpers or a test-only constructor). Production `withMultiProgress` / `withStepProgress` public API for Main/Apply stays unchanged.

**Rationale:** Real TTY flakes cannot be forced in CI; a “draw bomb” reproduces abandoned-lock class and proves no-hang under B2.

**Alternatives:** Only integration `script` smoke (flaky, slow); no seam (cannot regression-test the bug).

### 5. Narrow module scope

**Choice:** All production code edits in `src/CLI/Progress.hs` (+ tests). Do not “harden” Jobs/Apply/Go in this change.

**Rationale:** Agreed product scope; other sites already use `withMVar`/`bracket`/`mapConcurrently` and do not use this fork/join pattern.

### 6. Multi and step share the pattern

**Choice:** One teardown pattern for both hosts (extract shared host runner if it reduces duplication without a large rewrite).

**Rationale:** Step panel duplicates the same stop/done/drawLock bug class.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Cancel mid-ANSI leaves partial escapes on TTY | Best-effort clear in panel `finally` under `withDrawLock`; rare path only after grace |
| Grace too short → unnecessary cancel under load | 300ms ≫ one 80ms tick; adjust constant if smoke shows cancel storms (unlikely) |
| Grace too long → rare hang still feels sticky | Cancel still bounds worst case; primary path is cooperative exit in one tick |
| Test seam adds API surface | Keep production wrappers thin; seam package-internal or clearly test-oriented |
| `waitCatch` swallows panel bugs silently | Optional debug log; no-hang tests cover intentional draw bombs |
| Async exception masking gaps | Rely on `withMVar`/`async` library contracts; avoid bare take/put |

## Migration Plan

1. Implement lock helper + B2 host for multi and step; keep public entry points stable.
2. Add no-hang unit tests; run full suite / `hk check` as usual.
3. Manual TTY smoke: `outdated`, and `update` preflight step bar if convenient.
4. Rollback: revert `CLI.Progress` (+ tests); no data/config migration.

## Open Questions

None blocking. Grace micros can be chosen at implement time within 200–500ms without revisiting design.
