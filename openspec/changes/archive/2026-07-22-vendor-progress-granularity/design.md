## Context

`update` phase 1 already uses multi-progress (`CLI.Progress.MultiHandle`) for concurrent package apply. Go tree-lane **planning** advances a per-package step bar through ceilings / list / probe via `PlanProgress` hooks. After planning, **materialize** only budgets three apply steps per PV—`vendoring`, `publishing assets`, `regenerating manifest`—and `buildVendorTarball` runs clone → Go gate → `go mod download` → xz tar with no progress callbacks. Publish work (sidecars, commit, push, create release, upload) is similarly one frozen label.

Reuse is slightly better (three labels) but still uses the same coarse `* 3` step budget as full path. Release-asset lookup has no status, so multi-PV runs can sit on the previous PV’s last label during the probe.

Constraints: indicators only when TTY and not `--no-progress`; no nested bars; functional vendor/publish behavior must not change; tests already inject `VendorOps` / `ReleaseOps`.

## Goals / Non-Goals

**Goals:**

- Advance the per-package step bar through discrete full-path and reuse-path phases so operators see orientation and real progress.
- Use short, stable status names that distinguish full path from reuse.
- Show a non-advancing probe status before path selection.
- Thread progress through vendor construction without coupling `Update.Go.Vendor` to `layoutz`.
- Keep tests able to assert step/status event sequences with no-op or logging progress.

**Non-Goals:**

- Elapsed-time / heartbeat suffixes on long steps.
- Streaming `go` / `tar` / HTTP tool output into the progress row.
- Nested progress bars or a new progress host API beyond existing `mhStatus` / `mhSteps` / `mhStep`.
- Changing tarball format, publish semantics, reuse short-circuit rules, or step granularity for non-Go techniques (beyond leaving their current labels alone).
- Splitting create-release from upload, or exposing hash/sidecar write as separate steps.

## Decisions

### 1. Full path = 7 steps; reuse path = 3 steps

| Path | Steps (in order) |
|------|------------------|
| Full | `cloning upstream` → `go mod download` → `compressing tarball` → `committing assets` → `pushing assets` → `uploading release asset` → `regenerating manifest` |
| Reuse | `reusing release assets` → `verifying vendor asset` → `regenerating manifest` |

**Rationale:** Matches the long-running operator-visible seams. Host Go gate stays inside the download step (too short for its own bar slot). Hash + sidecars fold into `committing assets`. Create release folds into `uploading release asset`.

**Alternatives considered:** Status-only labels without step advances (weaker bar); finer publish split including sidecars/create-release (noise without much value).

### 2. `VendorProgress` callback bag (mirror `PlanProgress`)

Add a small progress record (or parameters) passed into `buildVendorTarball`:

- start/done hooks for clone, go-mod download, compress (or equivalent: status at start + step complete at end).

Apply wires hooks to `mhStatus` / `mhStep`. Production tests use a recording no-op. `VendorOps` stays process injection only.

**Rationale:** Keeps vendor module free of UI; same pattern as planning; easy unit tests.

**Alternatives considered:** Pass `MultiHandle` + `PackageKey` into vendor (tighter coupling); only call progress from Apply around the whole `buildVendorTarball` (cannot subdivide).

### 3. Publish phases report from Apply

Commit / push / upload already live in `fullPublishAndOverlay`. Call `mhStatus` before each block and `mhStep` after success. No new publish-progress type unless tests need one later.

### 4. Step totals: upper-bound full path, revise after probe

- After planning, set package step total to `planDone + (#materialize PVs × 7)` (or revise incrementally without a stale `* 3`).
- Before each PV path body, after release probe: set remaining budget so this PV contributes 7 (full) or 3 (reuse), with remaining unstarted PVs still counted as 7 each (upper bound).
- Non-advancing `mhStatus` during probe (e.g. `probing release asset`).

**Rationale:** Full vs reuse is unknown until probe; overestimating then revising down avoids a bar that only grows mid-flight and under-reports early. Existing `mhSteps` already revises total while keeping done.

**Alternatives considered:** Always 7 and “skip” steps on reuse (misleading); fixed 3 forever (status of quo).

### 5. Spec surface

Modify `cli-activity` (normative step names / telemetry) and `update-command` (examples / cross-ref). No `go-vendor-assets` delta—product pipeline unchanged.

### 6. Failure behavior

On hard-fail mid-path, leave the current step name as the last active phase (existing multi-progress failure row behavior). Do not advance `mhStep` for incomplete work. No new failure glyphs.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Step total mis-accounting (bar > 100% or stuck fraction) across multi-PV full/reuse mix | Centralize budget math in one helper; unit-test full→reuse and reuse→full sequences |
| Progress hooks forgotten on a new vendor substep | Keep all vendor IO in `buildVendorTarball` with hooks at existing seams only |
| Status strings drift from specs | Spec lists exact phrases (or required substrings); tests assert event names |
| Slightly more apply complexity | Isolated to Go materialize path; GitMv etc. unchanged |
| Probe status flashes quickly | Acceptable; still prevents stale previous-PV label |

## Migration Plan

- Pure UX change; no config, flags, or data migration.
- Ship behind existing indicator gate (TTY + not `--no-progress`); non-TTY behavior unchanged.
- Rollback: revert apply/vendor progress wiring; functional paths remain identical.

## Open Questions

_(none — resolved in exploration)_
