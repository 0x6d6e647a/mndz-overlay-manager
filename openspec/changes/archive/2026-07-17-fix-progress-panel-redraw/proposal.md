## Why

When activity indicators are enabled, multi-progress panels (notably `outdated`’s “Checking packages”) leave stacked progress lines instead of redrawing in place. The hand-rolled frame writer desyncs cursor position from stored line count whenever the panel **shrinks** (package rows removed on success), so later frames move up too few lines and ghost top-bar snapshots remain in the terminal. This is a correctness bug in the current host; it should be fixed under the existing architecture before any optional rewrite of the progress host.

## What Changes

- Fix multi-line panel redraw so after every frame the cursor sits just below the **current** content and the stored height matches that distance (same invariant `clearLines` already upholds on full clear).
- Extract pure draw planning (move-up / content / clear-extra / move-back / store-count) so grow, shrink, same-height, and empty cases are unit-testable without a TTY.
- Apply the fix to the shared path used by multi-progress and sequential step bars (both call the same frame writer).
- Keep worker APIs (`MultiHandle`, `StepHandle`), log hold, pause/resume for GPG, layoutz **widget** rendering, and machine stdout contracts unchanged.
- Non-goals: stable-height UX polish, soft-wrap / terminal-width handling, layoutz `runInline` / Elm runtime (see follow-on change `layoutz-progress-host`).

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `cli-activity`: Require in-place multi-line panel redraw—variable height (rows appear/disappear) MUST NOT leave ghost indicator lines; panel clear MUST remove the full owned band before deferred logs/stdout.

## Impact

- **Code**: `src/CLI/Progress.hs` (`drawFrame`, possibly thin pure helper; multi/step loops only if they store height incorrectly).
- **Tests**: unit tests for pure draw plan / height invariant; existing multi-progress state tests remain.
- **Manual**: TTY smoke of `outdated` (and optionally `update` phase 1) should show one living panel, then a clean clear, then report lines—no stacked “Checking packages …” history.
- **Dependencies**: none new.
- **Follow-on**: `layoutz-progress-host` depends on this change landing first so a runtime swap can use post-fix behavior as the parity oracle.
