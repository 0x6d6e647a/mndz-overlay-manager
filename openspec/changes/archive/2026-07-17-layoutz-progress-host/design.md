## Context

Post-`fix-progress-panel-redraw`, `CLI.Progress` correctly owns multi-line redraw via a pure draw plan and ANSI emit, with a tick loop, `lineCountRef`, `drawLock`, and pause/resume for GPG (`withUiSuspended`). layoutz is used for **widgets** (`inlineBar`, `spinner`, `layout`, colors), not for the **host** (`runInline` / `LayoutzApp`). The original activity-indicators design preferred layoutz for multi-line inline animation; this change is an optional experiment to move host ownership into layoutz while keeping product contracts and worker call shapes.

**Hard prerequisite:** do not implement until A is on the branch under test. A’s behavior and pure state/frame fixtures are the parity oracle.

## Goals / Non-Goals

**Goals:**

- Host multi-progress and sequential step bars with layoutz inline/runtime redraw so the project no longer owns CUU/line-count frame geometry for those panels.
- Preserve: stderr-only chrome, enablement gate, log hold, deferred stdout after clear, multi-progress row rules (success remove / fail retain / step telemetry), step bars for preflight/commits, `withUiSuspended` semantics for pinentry.
- Keep package workers concurrent via jobs pool; bridge status updates into the runtime without redesigning Check/Apply/Go planning.
- Decide keep vs revert with explicit kill criteria after a spike and parity check.

**Non-Goals:**

- Full-screen alt-screen TUI as the default for `outdated`/`update`.
- New indicator features, nested UIs, or stable-height product mode (unless free).
- Soft-wrap / width policy (separate).
- Weakening GPG readiness or log-hold rules to make the runtime fit.

## Decisions

### 1. Prerequisite and parity oracle

**Choice:** Implement only after `fix-progress-panel-redraw`. Treat post-A interactive behavior and pure multi-state → frame content as acceptance for C.

**Rationale:** Avoid mixing geometry bugs with runtime integration bugs.

**Alternatives:** Port broken host first — rejected.

### 2. Spike pause/resume before full host swap

**Choice:** First spike: can layoutz inline runtime clear the panel region and fully yield stderr/TTY for pinentry, then resume or restart the panel without ghost lines or stuck input? If no clean path within a short spike, archive as rejected with notes.

**Rationale:** Pause is the product hard edge; bars are secondary. Fail fast.

**Alternatives:** Full rewrite then discover pause is impossible — wasted work.

### 3. Keep MultiHandle / StepHandle at the worker boundary

**Choice:** Workers continue to call `mhStart` / `mhStep` / `mhSuccess` / … (and `shStep`). Internally those enqueue messages or update state the layoutz app reads. Do not push Elm types into `Update.Check` / `Update.Apply`.

**Rationale:** Minimizes blast radius; isolates experiment to Progress (and thin glue).

**Alternatives:** Runtime drives package work via Cmd — rejected for this experiment (too large).

### 4. Prefer `runInline` over alt-screen `runApp`

**Choice:** Use inline embedding (layoutz `runInline` or equivalent options that do not take over the full terminal / clear scrollback by default). Indicators stay on stderr if the library allows configuring the handle; if not, document and either adapt carefully or reject.

**Rationale:** CLI must leave machine stdout clean and preserve scrollback for operators.

**Alternatives:** `runApp` with clear-on-start — wrong product shape for this tool.

### 5. Kill / keep criteria

**Keep C if:**

- Pause/resume for GPG is clean (clear panel, pinentry works, resume or re-show without ghosts).
- Worker bridge stays thin (Progress-local).
- Clear + log-hold + deferred stdout parity with post-A.
- Net reduction of project-owned multi-line ANSI geometry.

**Revert C if:**

- Must tear down half the process model for pinentry.
- Bridge forces Check/Apply redesign.
- Ghost lines, stdout pollution, or flaky redraw return.
- More glue than post-A `drawFrame` / planner.

### 6. Reuse A’s pure content fixtures

**Choice:** Keep `renderMulti` / multi-state tests (or equivalent view pure functions) as the definition of **what** to show; only the host that paints them changes.

**Rationale:** A’s tests remain valuable as parity under C.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| layoutz runtime hard to pause for pinentry | Spike first; reject if unclean |
| Runtime writes stdout or wrong handle | Verify stderr-only; reject or wrap |
| Concurrent workers race the Elm update thread | Single mailbox; workers only send msgs |
| Variable height bugs reappear inside layoutz | Parity smoke vs post-A; upstream issue notes |
| Experiment drags on | Time-box spike; explicit archive path |
| Double systems mid-migration | Feature-complete cutover per panel type; no long dual-host |

## Migration Plan

1. Confirm A is applied; baseline TTY smoke green.
2. Spike pause + clear + resume with layoutz inline on a minimal panel.
3. If spike OK: implement multi-progress host, then step bars; keep MultiHandle/StepHandle.
4. Parity: unit view tests + TTY `outdated` / `update` (including GPG suspend path if available).
5. Either merge and drop hand-rolled geometry, or revert and archive design notes.

Rollback: git revert of this change only; A remains.

## Open Questions

- Exact layoutz 0.3.x APIs for stderr handle and pause (resolve in spike).
- Whether sequential step bars share one app type or two thin apps with shared host helpers.

## Spike outcome (resolved)

**Experiment rejected.** Full notes: [SPIKE.md](SPIKE.md).

Against **layoutz 0.3.4.0**:

- `runInline` / `runAppWithFinal` write only to **stdout** (`putStr`); no handle option → fails stderr-only chrome.
- Runtime **owns stdin** (raw mode + key loop) until exit; **no pause/resume** for pinentry yield.
- **No external message mailbox** for concurrent workers; bridge would force Check/Apply into Elm `Cmd` (rejected non-goal).
- Inline render path still lacks shrink **move-back** (pre-A ghost-line class).

Kill criteria met: unclean pause, stdout pollution risk, non-thin bridge, no net reduction of project-owned multi-line geometry without reimplementing a host. **Keep post-A hand-rolled host** in `CLI.Progress`; continue using layoutz for widgets only. Revisit only if upstream adds stderr handle, pause/clear/yield, and external msg injection.
