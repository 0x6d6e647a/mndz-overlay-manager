## 1. Release lookup and download

- [x] 1.1 Add injectable assets/release ops: get release by tag, find asset by exact name, download asset to path (not-found distinct from hard errors)
- [x] 1.2 Wire production HTTP implementation for `GET …/releases/tags/{tag}` + asset download (token headers as create-release)
- [x] 1.3 Unit tests with mock manager/ops for found, missing tag, missing asset name

## 2. Needs-work detection (Manifest + content)

- [x] 2.1 Extend content/Manifest fix helpers used by Check and Apply: planned PV with local ebuild still needs work if Manifest lacks DIST for `{pn}-{pv}-vendor.tar.xz`
- [x] 2.2 Keep existing SRC_URI / BDEPEND / KEYWORDS checks; soft-skip only when all planned PVs pass content **and** Manifest vendor DIST presence
- [x] 2.3 Unit tests: missing vendor DIST → needs work; complete Manifest + good ebuild → no content fix

## 3. Reuse materialize path

- [x] 3.1 Before full `goPublishAndOverlay`, probe release+asset; on not-found keep existing full vendor+publish path
- [x] 3.2 Reuse path: download asset → multi-hash digests → optional sidecar SHA512 cross-check when sidecars exist → overlay rewrite (SRC_URI, KEYWORDS, BDEPEND from go.mod probe without vendor clone) → `ebuild … manifest` → Manifest SHA512 vs download
- [x] 3.3 Skip host Go gate, assets git lock, and create-release on reuse path; same-PV `-rN` still reuses unrevisioned release tag
- [x] 3.4 Track per-PV materialize mode (full vs reuse) for reporting/progress
- [x] 3.5 Tests: injected not-found → full path ops called; found → no vendor/publish, overlay+verify only; Manifest mismatch hard-fails

## 4. Operator transparency

- [x] 4.1 Multi-progress: reuse statuses (`reusing release assets`, `verifying vendor asset`, then manifest regen); full path keeps vendoring/publishing
- [x] 4.2 Outdated: append ` [assets reusable]` for same-PV overlay/Manifest content-fix lines (no GitHub probe required in outdated)
- [x] 4.3 Update success stdout: append ` [assets reused]` for PVs completed via reuse path
- [x] 4.4 Deferred logs: info lines naming release tag and asset on reuse

## 5. Quality gates

- [x] 5.1 Format and `cabal test all` / `hk check` green
- [x] 5.2 Manual smoke notes (operator): re-run after orphan publish → reuse path completes Manifest without create-release error; KEYWORDS-only fix with existing release → no multi-minute vendor

### Operator smoke notes (5.2)

1. **Orphan resume**: After a run that published `{pn}-{pv}` release assets but left overlay/Manifest incomplete, re-run `mndz-overlay-manager update <pkg>`. Expect progress steps `reusing release assets` / `verifying vendor asset` / `regenerating manifest` (not vendoring/publishing), success line with ` [assets reused]`, and no create-release failure for an existing tag.
2. **KEYWORDS-only / content-only**: With a local ebuild that needs KEYWORDS (or SRC_URI/BDEPEND/Manifest) fix while release `{pn}-{pv}` already has `{pn}-{pv}-vendor.tar.xz`, run `update`. Expect no multi-minute vendor rebuild; `outdated` may show ` [assets reusable]` for that same-PV line beforehand.
