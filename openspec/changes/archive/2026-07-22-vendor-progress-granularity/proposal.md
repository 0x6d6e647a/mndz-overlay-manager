## Why

When applying Go vendor packages, the multi-progress row freezes on coarse labels (`vendoring`, `publishing assets`) for long stretches while clone, `go mod download`, xz compression, git push, and release upload each run. Operators cannot tell which phase is active or that work is still progressing. Planning already has fine step telemetry; the materialize path needs the same treatment.

## What Changes

- Split the full vendor+publish apply path into real per-package multi-progress steps with distinct status names (clone, go mod download, compress, commit assets, push assets, upload release asset, regenerating manifest).
- Keep the reuse path’s three phases as first-class steps (`reusing release assets`, `verifying vendor asset`, `regenerating manifest`) under the same step-accounting model.
- Show a short non-advancing status while probing for an existing release asset before choosing full vs reuse.
- Revise per-package step totals when the path is known (upper-bound full-path budget; revise down on reuse) so the step bar advances through real work instead of three opaque buckets per PV.
- No elapsed-time suffixes, no subprocess log streaming into the row, no nested progress bars, and no functional change to vendoring or assets publish behavior.

## Capabilities

### New Capabilities

_(none)_

### Modified Capabilities

- `cli-activity`: Require finer step telemetry and status names for full and reuse Go vendor materialize paths; keep reuse wording rules; forbid claiming vendoring/publishing on reuse.
- `update-command`: Align phase-one multi-progress examples with the finer full-path sub-phases (point at or match `cli-activity`).

## Impact

- **Code**: `Update.Go.Vendor` (progress callbacks through `buildVendorTarball`), `Update.Apply` (`fullPublishAndOverlay`, `reuseReleaseAsset`, `materializePlan` step budget), possibly thin hooks around assets commit/push/upload already in apply.
- **UI**: Existing `CLI.Progress` multi-handle (`mhStatus` / `mhSteps` / `mhStep`); no new progress host APIs required unless tests need a no-op progress record.
- **Specs**: Delta requirements under `cli-activity` and `update-command` only; `go-vendor-assets` / `assets-publish` product behavior unchanged.
- **Tests**: Progress event logging for full vs reuse paths (same style as plan-progress tests); existing vendor/reuse functional tests remain.
- **Docs**: Operator-facing README only if progress wording is documented there (unlikely); no CLI flag changes.
