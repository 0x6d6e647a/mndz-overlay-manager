## Why

After `fix-progress-panel-redraw`, the hand-rolled multi-progress host is correct but still owns ANSI cursor math, a tick loop, and line-count bookkeeping. The original activity-indicators design preferred layoutz’s inline/runtime path for multi-line animation; this change is an **optional architectural experiment** to swap the panel host to layoutz (`runInline` / `LayoutzApp` or equivalent) while preserving post-fix-A behavior. It must not start until A is applied so success/failure of the experiment is not confounded by the old shrink bug.

## What Changes

- **Prerequisite**: `fix-progress-panel-redraw` applied (or equivalent in-place redraw already on main). Do not implement this change first.
- Replace (or reimplement behind) the multi-progress and sequential step-bar **host**—tick loop, `drawFrame` / line-count ownership—with a layoutz-driven inline runtime that owns frame redraw and clear-on-exit for the panel region.
- Keep the external product surface: stderr-only chrome, TTY/`--no-progress` gate, log hold during panels, deferred machine stdout after clear, `MultiHandle` / `StepHandle` (or a thin adapter with the same call semantics), and `withUiSuspended` / pause for GPG pinentry.
- Bridge concurrent package workers into the runtime via messages (or shared state the runtime reads); do **not** redesign Go planning, check/apply techniques, or job pools.
- Spike pause/resume against layoutz early; if the runtime cannot clear and yield the TTY cleanly for pinentry, document rejection and stop rather than weakening GPG readiness.
- Explicit escape hatch: if the host swap costs more glue than it removes, or breaks pause/parity, archive as a rejected experiment and keep the post-A hand-rolled host.
- Non-goals for this experiment: new indicator types, alt-screen full TUI (`runApp` defaults that clear the terminal), soft-wrap policy, stable-height product mode (unless free with the runtime).

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `cli-activity`: Strengthen layoutz-backed presentation so activity **panels** (multi-progress and sequential step bars) are hosted by layoutz inline/runtime redraw, not a project-owned multi-line ANSI frame writer—while preserving existing enablement, stderr-only, log-hold, multi-progress row rules, and clear-before-deferred-output requirements.

## Impact

- **Code**: primarily `src/CLI/Progress.hs`; possibly thin adapters; `Update.GpgAgent` / `withUiSuspended` integration; tests that assume the hand-rolled host.
- **Dependencies**: existing `layoutz`; may exercise more of its TUI/runtime API (`runInline`, `LayoutzApp`, subscriptions).
- **Risk**: high relative to A—concurrency bridge and pinentry pause are the hard edges; bars alone are not.
- **Rollback**: revert this change only; post-A redraw correctness remains.
- **Ordering**: implement only after `fix-progress-panel-redraw` is done; use A’s pure frame/state fixtures as parity checks where practical.
