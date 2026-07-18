## Why

After assets publish succeeds, overlay failures leave orphan releases: re-running `update` soft-skips (ebuild looks fine while Manifest is incomplete) or re-enters the full vendor path and dies when the GitHub release tag already exists. The same full path also re-vendors and re-publishes for tree-lane content-only fixes (KEYWORDS, BDEPEND, SRC_URI) when the vendor tarball for that PV is already on a release—expensive churn that F1 in `go-vendor-assets-update` deferred. We need an idempotent **reuse** path for planned Go PVs whose release assets already exist, with heavy integrity checks and clear operator visibility.

## What Changes

- When materializing a planned `GoVendorAndAssets` PV, **probe** the assets repo for release tag `{pn}-{pv}` and the expected vendor asset; if present, **skip** clone, vendor construction, assets git commit/push, and release create/upload.
- On that **reuse path**: download the remote vendor asset, compute digests, rewrite overlay ebuild content as needed, run `ebuild … manifest`, and **verify** Manifest SHA512 against the downloaded asset (heavy verify). Optionally cross-check assets-repo sidecars when present.
- Extend “needs work” detection so incomplete or stale **Manifest** vendor entries (not only SRC_URI / BDEPEND / KEYWORDS) prevent soft-skip when a planned PV is otherwise present.
- Keep the **full** vendor+publish path when the release or expected asset is missing (first-time PV or incomplete publish).
- Surface reuse vs full mode transparently in multi-progress status, outdated/success reporting, and deferred logs.
- Non-goals: force re-upload/replace of existing release assets; dirty `--force` (F3); `GOTOOLCHAIN` policy (done in `go-vendor-toolchain` / F2); non-Go assets techniques.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `go-vendor-assets`: Reuse existing GitHub release vendor assets for planned PVs; heavy download+hash verify; Manifest-aware “needs work” (incomplete/stale vendor DIST prevents soft-skip); overlay-only apply when assets are already published; full vendor+publish path when the release or expected asset is absent.
- `assets-publish`: Support looking up an existing release by tag and downloading a named asset for reuse/verify (without requiring create-release for that PV).
- `update-apply`: Go multi-lane apply uses the reuse short-circuit; half-applied / orphan resume completes via overlay-only when assets already exist.
- `outdated-command`: Operator-visible labeling when a package needs overlay or Manifest work while release assets are already present (or can be reported as reuse-eligible content fix).
- `update-command`: Success/outcome messaging distinguishes assets-reused overlay completion from full vendor+publish bumps.
- `cli-activity`: Multi-progress status/step strings for the reuse path so TTY runs do not claim “vendoring” or “publishing assets” when those steps are skipped.

## Impact

- **Code**: `Update.Apply` (`goPublishAndOverlay` / `materializeOne` / `contentFixNeeded`); `Update.Check` content-fix parity; `Update.Assets.Release` (get release by tag, list/download asset); digests reuse; progress status wiring; possibly small reporting helpers for outdated/success lines.
- **Operator**: Re-runs after orphan publish complete overlay without release-create failures; KEYWORDS/BDEPEND-only lane churn avoids multi-minute vendor rebuilds; host Go gate does not block reuse-only work; mode is visible in progress and reports.
- **External**: GitHub API read + asset download for existing releases (token as today); no new config keys expected.
- **Tests**: Pure detection helpers; injectable release lookup/download; unit tests for Manifest-needs-work and reuse branch selection; no live GitHub required in CI.
- **Out of scope**: F3 dirty force; force re-vendor of an existing good release; npm/other techniques.
