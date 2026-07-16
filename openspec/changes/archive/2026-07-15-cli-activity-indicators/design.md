## Context

`outdated` runs sequential `mapM checkPackage` with no progress UI. `update` already uses `mapConcurrently` for phase 1 and sequential commits, also without progress. Machine stdout (`category/package vLOCAL -> vREMOTE`) and co-log stderr (warnings/errors) are emitted after work completes today for reports/outcomes, which is compatible with a “panel then flush” model.

Logging uses `cmap fmtMessage logTextStderr`. co-log’s `fmtMessage` already colors severity tags, but the palette is stock (Debug green, Info blue, …), there is no `NO_COLOR` support, and `optVerbosity` is never applied. The verbosity parser’s `--log-level` option uses `value Warn`, which prevents the `-v` alternative from running.

Interactive multi-progress is a cross-cutting concern: CLI flags, logging bootstrap, check/apply concurrency, and presentation must stay consistent without corrupting stdout contracts.

## Goals / Non-Goals

**Goals:**

- Interactive multi-progress for concurrent package work on `outdated` and `update` phase 1 via `layoutz`.
- Sequential progress bars for `update` preflight steps and signed-commit phase.
- Parallelize `outdated` checks under a bounded job pool shared with update apply.
- Global `--jobs`, `--no-progress`, `--no-color`; honor `NO_COLOR`.
- Fix verbosity filtering and `-v` parsing; adopt the agreed severity color palette.
- Queue logs (and keep machine stdout emission) until indicators clear; fail lines remain on the panel until clear.

**Non-Goals:**

- Progress for config load / overlay discovery spine (later).
- Multi-progress for sequential commits (bar only).
- Replacing co-log with layoutz for log line formatting.
- Timestamps / `fmtRichMessageDefault` restoration.
- Guaranteeing zero garbling if child processes bypass capture (best effort only).

## Decisions

### 1. `layoutz` for activity UI only

**Decision:** Depend on `layoutz` for bars, spinners, and multi-line inline animation (`runInline` / `LayoutzApp` or equivalent). Do not use layoutz to format co-log messages.

**Rationale:** Matches the multi-progress product vision; spinners, `inlineBar`, colors, and inline apps are first-class. Built-in `loader` is sequential-only and insufficient for concurrent package rows.

**Alternatives:** `terminal-progress-bar` (determinate single bar, no multi-spinner); hand-rolled ANSI (more maintenance for multi-line redraw).

### 2. Multi-progress state machine

**Decision:** One shared panel model for concurrent package jobs:

```
top:   <label> [bar] done/total
rows:  active jobs → spinner + package key + optional phase text
       failed/soft-fail → static glyph + short reason (remain)
       success → row removed, done++
```

When `done == total`, clear the panel, then flush queued logs and stdout lines in stable order (package-key sorted, matching current emit order preferences).

**Rationale:** User-specified UX; fail visibility without interleaving full log text mid-panel.

**Implementation sketch:** `MVar`/`STM` job map + tick subscription for spinner frames; workers update status; app exits with `CmdExit` when all terminal.

### 3. Concurrent `outdated` + bounded jobs

**Decision:** Change `checkOverlay` (or its caller) to run package checks concurrently through a shared pool of size `--jobs` (default `GHC.Conc.getNumProcessors`). Reuse the same bound for `applyOverlay` phase 1 instead of unbounded `mapConcurrently`.

**Rationale:** Multi-progress implies useful concurrency for checks; rate-limit escape hatch via `--jobs`.

**Alternatives:** Keep sequential outdated (weaker UX); unbounded concurrency (simpler, riskier for APIs).

### 4. Preflight and commit indicators

**Decision:** Sequential determinate bars: `done/total` + current step/package description; clear on complete. Preflight steps include PATH tool checks and conditional assets/token/ssh-agent setup as distinct steps where natural. Commits: one bar over successful phase-1 packages being committed.

**Rationale:** Work is sequential; multi-rows add noise.

### 5. Go (and future technique) sub-phase labels

**Decision:** Phase-1 package rows may update phase text in v1 (e.g. fetching, vendoring, publishing assets, manifest). No nested progress bars per package.

**Rationale:** Long Go work otherwise looks stuck; labels are enough until techniques get richer telemetry.

### 6. Logging stays co-log; custom severity format

**Decision:** Keep co-log `Message` + `LogAction`. Implement custom severity coloring:

| Level | Color when enabled |
|-------|--------------------|
| Info | Green |
| Warning | Yellow |
| Error | Red |
| Debug | Magenta |

Respect `--no-color` and non-empty `NO_COLOR` env (disable ANSI in severity tags and in layoutz chrome). Optionally disable color when stderr is not a TTY.

**Rationale:** Already integrated; layoutz per log line is overhead without benefit; raw escape strings are worse than `ansi-terminal`.

### 7. Verbosity wiring and parser fix

**Decision:**

- After parse, build `LogAction` with `filterBySeverity` from CLI verbosity mapped to co-log `Severity`.
- Default level: Warning.
- Combine `--log-level` and `-v` without `option … value` short-circuiting `-v`: e.g. optional `--log-level`, and `-v` count that steps Warn→Info→Debug (or explicit level wins when both set—prefer last wins or document: `--log-level` overrides if present, else `-v` count from Warn).
- Recommended rule: if `--log-level` appears, use it; else default Warn plus one step per `-v` (cap Debug).

**Rationale:** Spec and help already claim this; current code is non-functional.

### 8. Indicator gating

**Decision:** Show indicators only when all of:

1. stderr is a terminal (`hIsTerminalDevice stderr`)
2. `--no-progress` is not set

When disabled, behavior matches today’s non-UI path: no panel, immediate log emission (subject to severity filter), same stdout contract.

### 9. Log queue during indicators

**Decision:** While a panel is active, log actions enqueue messages instead of writing. After clear, dequeue in order through the normal formatter. Machine stdout success/outdated lines also wait until after clear (emit path in Main).

**Rationale:** Avoids co-log fighting `\r`/cursor redraw; keeps stdout pure.

### 10. Child process I/O

**Decision:** Best-effort capture of `git` / `ebuild` / `go` / related process stdout+stderr into buffers; surface tails on hard fail after clear. Do not claim perfect isolation.

### 11. Module layout

**Decision (suggested):**

- `CLI.Progress` or `Ui.Activity` — gating, multi-progress host, step bar, queue hooks
- `CLI.Jobs` or concurrency helper — pool / `QSem` around package work
- Extend `Logging.Bootstrap` — `mkLogger :: Verbosity -> ColorMode -> LogAction …`, severity format, optional queue handle
- Wire from `app/Main.hs`; thin callbacks into Check/Apply

Library code remains testable without TTY by injecting a no-op progress backend.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| `layoutz` `runInline` + concurrent workers race | Single writer for panel state; workers only update shared status |
| Child tools still print to TTY | Capture process handles; fix remaining garble as found |
| GitHub rate limits under default jobs | `--jobs` default nproc; user can lower; document |
| `-v` / `--log-level` interaction surprises | Document override rule in help; tests for combinations |
| Changing severity colors surprises users | Intentional product decision; document in help/changelog |
| Terminal width / multi-line clear glitches | Prefer layoutz clear-on-exit; keep panel height stable when possible |
| Tests flaky if progress assumes TTY | Force no-progress in tests; unit-test pure formatters/pool |

## Migration Plan

1. Land dependency + flags + logger fix (behavior-preserving for stdout when non-TTY).
2. Add progress backend with no-op path defaulted in tests.
3. Parallelize outdated + bound update jobs.
4. Enable multi-progress on TTY for outdated, then update phases.
5. No data migration; pure CLI UX.

Rollback: revert change; no on-disk format impact.

## Open Questions

None blocking implementation. Optional later: treat `CI=true` as force no-progress; restore timestamps on rich logger.
