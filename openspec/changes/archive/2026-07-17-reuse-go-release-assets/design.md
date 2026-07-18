## Context

`GoVendorAndAssets` materialization always runs: temp clone → host Go gate → `go mod download` vendor tarball → assets sidecars + push → create GitHub release + upload → overlay ebuild rewrite → `ebuild … manifest` → Manifest SHA512 vs built digests.

That path is wrong when the release tag `{pn}-{pv}` already has the expected `{pn}-{pv}-vendor.tar.xz` asset (half-apply after successful publish; KEYWORDS/BDEPEND/SRC_URI-only lane churn; re-admitting a previously published PV). Today re-runs either soft-skip (content looks fine while Manifest is incomplete—`contentFixNeeded` ignores Manifest) or hard-fail on create-release because the tag exists.

F1 from `go-vendor-assets-update` described resume; exploration narrowed scope to **reuse existing release assets** with heavy verify and transparent operator UX. F2 (`go-vendor-toolchain`) is already shipped (host Go gate + BDEPEND). F3 dirty force is out of scope.

## Goals / Non-Goals

**Goals:**

- Before vendor+publish for a needed planned PV, detect an existing assets release + expected vendor asset; if present, take an **overlay-only reuse path**.
- **Heavy verify**: download the asset, compute digests, run overlay + `ebuild … manifest`, require Manifest SHA512 to match the downloaded digest (optional sidecar cross-check when present).
- Extend **needs work** so incomplete/stale Manifest vendor DIST for a planned PV is not soft-skipped.
- **Transparent** progress, outdated, and success messaging for reuse vs full vendor+publish.
- Preserve full path when release or asset is missing; keep assets-before-overlay ordering for the full path.

**Non-Goals:**

- Force re-upload or replace an existing release asset.
- F3 `--force` / dirty path override.
- Changing host Go / `GOTOOLCHAIN` policy (F2 done).
- npm/bun assets techniques (reuse API can stay generic enough for later).
- Skipping Portage fetch on overlay path (still real `ebuild … manifest`).

## Decisions

### 1. Branch at materialize: probe then reuse or full

**Choice:** In `goPublishAndOverlay` (or a thin wrapper), call `lookupReleaseVendorAsset(pn, pv)` first.

- **Found** → reuse path (no clone, no vendor, no assets lock/push, no createRelease).
- **Not found** → existing full path unchanged.

**Rationale:** Single rule covers orphan resume, content-only fixes, and lane re-admit of old PVs. No half-apply state machine or durable run journal.

**Alternatives:** Always rebuild (status quo); soft “ensure release” that re-uploads on conflict — rejected (silent mutation of published artifacts).

### 2. Heavy verify always on reuse

**Choice:** Download the release asset to a temp file; compute the same multi-hash family used for vendor publish (at least SHA-512 for Manifest compare; SHA-256/BLAKE3 as available for parity/sidecar checks). After `ebuild … manifest`, require Manifest vendor SHA512 == downloaded SHA512.

If assets-repo sidecars exist for that tarball basename and their SHA512 disagrees with the download, hard-fail with an out-of-sync message (do not rewrite sidecars on reuse).

**Rationale:** Operator chose heavy trust; name-only presence is insufficient. Portage still fetches the public URL; we ensure Manifest matches the same bytes we downloaded from the release.

**Alternatives:** HEAD-only; sidecar-only without download — rejected for this change.

### 3. Manifest participates in needs-work detection

**Choice:** Extend content/Manifest fix detection used by `outdated` and `update` for planned PVs:

A present local ebuild for planned PV still “needs work” if any of:

- assets SRC_URI not fully parameterized (existing),
- Go BDEPEND missing/wrong (existing),
- KEYWORDS mismatch plan (existing),
- **NEW:** package `Manifest` lacks a DIST line for `{pn}-{pv}-vendor.tar.xz`, or its SHA512 is known-stale when we already have a trusted expected hash (e.g. after reuse download, or when comparing is cheap); at minimum **missing vendor DIST** always counts as needs work.

**Rationale:** Fixes soft-skip after ebuild write + failed manifest (classic F1).

**Alternatives:** Only short-circuit materialize without detection — still soft-skips.

### 4. BDEPEND / go version on reuse without vendor clone

**Choice:** On reuse, obtain `go.mod` `go` directive from the existing lane probe cache / lightweight go.mod fetch for the tag (same data planning already uses). Do **not** run the host Go ≥ go.mod gate on the reuse path (no `go mod download`).

**Rationale:** Overlay-only work must not fail solely because host Go is older than a package whose vendor was already published. Full path retains F2 gate.

### 5. Operator transparency

**Choice:** Distinct surfaces:

| Surface | Full path | Reuse path |
|---------|-----------|------------|
| Multi-progress status | `vendoring` → `publishing assets` → `regenerating manifest` | `reusing release assets` → `verifying vendor asset` → `regenerating manifest` |
| Outdated / content-fix lines | existing lane gap format | same `vFROM -> vTO (lane)` when PV gap; for same-PV content/Manifest fix append a stable marker such as ` [assets reusable]` (or equivalent clearly visible token) |
| Success stdout | existing lane success lines | same line shape plus ` [assets reused]` on lines for PVs completed via reuse |
| Logs (after panel clear) | existing | info: release tag + asset name reused; verify complete |

**Rationale:** Operator must not wonder whether a re-run re-uploaded multi-hundred-MB vendors.

### 6. Assets API: lookup + download, create remains full-path only

**Choice:** Add injectable helpers on the assets/release client:

- get release by tag (`GET …/releases/tags/{tag}`)
- find asset by exact name
- download asset body to a path

Create-release+upload remains only on the full path. Reuse does not take the assets git critical section (read-only GitHub + optional local sidecar read).

**Rationale:** Avoid false “assets publish” serialization and accidental tag create.

### 7. Same-PV revision bumps still reuse

**Choice:** Release identity is `{pn}-{pv}` **without** `-rN`. Overlay may still bump `-rN` for content fixes while reusing the same release asset.

**Rationale:** Matches current release naming and SRC_URI `${PV}` (Portage PV without revision for distfile names as already specified).

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Extra download bandwidth on every reuse | Still far cheaper than vendor; only for PVs that need work |
| Large temp disk for download | System temp + delete after verify; same class as vendor out dir |
| Private/rate-limited GitHub | Reuse existing token + error mapping; hard-fail with clear message |
| Soft-skip still wrong if Manifest check incomplete | Minimum: missing vendor DIST; SHA compare after download on apply |
| Sidecar missing but release ok | Download+hash still proceeds; sidecar check only when file exists |
| Operator confuses success lines | Mandatory `[assets reused]` / progress status strings |
| Dirty paths still block resume | Document; F3 out of scope |

## Migration Plan

1. Land helpers + detection + reuse branch behind normal `update`/`outdated` paths (no feature flag required).
2. No main-spec sync of rejected layoutz host experiments; this change only touches listed capabilities.
3. Rollback: revert commit; full path remains correct (just less idempotent).

## Open Questions

- Exact outdated/success marker spelling (`[assets reusable]` vs `[assets reused]` vs longer phrase) — prefer short bracket tokens above unless implementation prefers a single shared phrase.
- Whether outdated should probe GitHub during check (network) or only label same-PV content/Manifest fixes as “may reuse” without confirming remote existence until apply. **Preference:** apply always probes; outdated may label local content/Manifest fixes without a network probe to keep `outdated` offline-friendly, and use the reusable marker when the fix is overlay-side (not missing PV that clearly needs full publish). Missing PV without local ebuild stays a normal gap line (full path expected).
