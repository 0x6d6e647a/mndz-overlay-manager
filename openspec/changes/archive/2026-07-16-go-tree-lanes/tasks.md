## 1. Gentoo Go ceilings

- [x] 1.1 Add injectable `portageq get_repo_path / gentoo` helper and resolve `dev-lang/go` directory
- [x] 1.2 Parse `go-*.ebuild` KEYWORDS and PV; ignore live/`9999`
- [x] 1.3 Compute four ceilings: amd64/arm64 × plain/~ with pure helpers and unit tests (fixture KEYWORDS samples)

## 2. Upstream version list and go.mod probe

- [x] 2.1 Extend GitHub client to list comparable versions (paginated tags/releases, prefix strip, PV order)
- [x] 2.2 Fetch `go.mod` body at tag + optional subdirectory (raw or Contents API; token-aware)
- [x] 2.3 Parse `go` directive with existing `Update.Go.Version` helpers; process-local cache by (repo, tag, subdir)
- [x] 2.4 Unit tests for list filtering and go_req extraction without live network where practical

## 3. Tree-lane planner

- [x] 3.1 Implement plan types: lanes, labels, unique PVs, KEYWORDS membership, gaps vs local ebuilds
- [x] 3.2 Select per-lane max PV with `go_req ≤ ceiling`; skip unparseable tags; handle empty ceilings
- [x] 3.3 Collapse to unique ebuild set; assemble `~arch` KEYWORDS only
- [x] 3.4 Exact-set diff: missing PVs, stale content, extras to delete
- [x] 3.5 Pure unit tests: collapse, arch divergence, four-distinct PVs, converge/split report mapping helpers

## 4. Ebuild edit and apply wiring

- [x] 4.1 KEYWORDS set/replace helper for planned `~amd64` / `~arm64` strings
- [x] 4.2 Refactor `GoVendorAndAssets` apply to iterate planned unique PVs (clone/vendor/assets/BDEPEND per PV)
- [x] 4.3 After successful materialization of all targets, prune non-target non-live ebuilds; safety if a target failed
- [x] 4.4 Per-lane signed commits with same-PV coalesce; stage deletions with package commit storm
- [x] 4.5 Wire host Go gate unchanged per PV; keep non-Go `GitMvAndManifest` latest-only

## 5. outdated and update CLI

- [x] 5.1 `outdated`: Go packages use planner; emit multi-line labeled gaps; non-Go unchanged
- [x] 5.2 `update` zero-arg selection includes Go lane gaps; explicit targets soft-skip when plan satisfied
- [x] 5.3 Success stdout: split/converge lines with `(dev-lang/go …)` labels
- [x] 5.4 Preflight: require `portageq` (or document failure mode) when any selected package is `GoVendorAndAssets`—or fail per-package on plan; prefer clear per-package errors if tree missing
- [x] 5.5 Integration-style tests with mocked portageq, version list, and go.mod fetch

## 6. Quality gates

- [x] 6.1 `hk fix` / ormolu on touched modules
- [x] 6.2 `cabal test all` and `hk check` green
- [x] 6.3 Manual smoke notes (optional): `outdated`/`update` on crush with dual ceilings if tree/upstream diverge

### Manual smoke notes (6.3)

On a Gentoo host with `portageq` and a readable gentoo tree:

```bash
# Report multi-lane gaps (labels like (dev-lang/go amd64))
mndz-overlay-manager outdated

# Apply tree-lane plan for crush (may create ≤4 ebuilds + prune extras)
mndz-overlay-manager update crush
```

Expect: when tree plain vs tilde Go ceilings diverge and upstream go.mod differs across tags, crush (and other Go packages) can materialize multiple PVs with `~arch` KEYWORDS only; commits one per distinct PV.
