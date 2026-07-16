## Context

`GoVendorAndAssets` apply clones a single target tag (today: upstream latest), vendors modules, publishes assets, and rewrites the overlay ebuild with BDEPEND from that tag’s `go.mod` `go` line. Host Go is gated at apply time (`go-vendor-toolchain`). Gentoo’s `dev-lang/go` has multiple ebuilds with divergent KEYWORDS per arch (`amd64` vs `~amd64`, `arm64` vs `~arm64`). Upstream packages often advance their `go` directive past what stable-keyworded Go provides while `~` Go is newer.

The overlay convention is **never bare stable package KEYWORDS** (always `~arch`). Users accept `~` for overlay packages; Portage then picks the newest package PV whose `>=dev-lang/go-…` BDEPEND is satisfiable. That only works if the overlay **maintains multiple PVs** when tree Go ceilings differ.

Today `outdated` / `update` use one local newest vs one remote latest. This change introduces a shared **tree-lane planner** for all `GoVendorAndAssets` packages.

## Goals / Non-Goals

**Goals:**

- For every `GoVendorAndAssets` package, plan up to four lanes: `{amd64, arm64} × {plain, ~}` Go ceilings from the gentoo tree
- Select max upstream package PV with `go_req(v) ≤ ceiling` per lane; collapse to unique ebuild PVs
- Exact-set package directory: only those ebuilds remain (no historical leftovers)
- `outdated` and `update` share the planner; bulk `update` selects packages with any lane gap
- Overlay package KEYWORDS always use `~` forms, arch-scoped by which lanes need each PV
- Stdout/outdated labels: `(dev-lang/go amd64)`, `(dev-lang/go ~amd64)`, `(dev-lang/go arm64)`, `(dev-lang/go ~arm64)`
- Split/converge reporting: multiple olds → one new and one old → multiple news on separate lines
- One signed commit per lane mutation (coalesce when two lanes share one PV write)
- Tree path via `portageq get_repo_path / gentoo` only
- Reuse existing vendor, assets, BDEPEND, and host Go gate for each target PV

**Non-Goals:**

- Host Go as a selection input (apply-time gate only)
- Config override for Gentoo tree path
- User `--version` pin CLI (future escape hatch)
- `GOTOOLCHAIN=auto` or non-distro toolchains
- Arches other than amd64 and arm64
- Changing non-Go techniques (`GitMvAndManifest` stays latest-only)
- Claiming stable (non-`~`) KEYWORDS on overlay packages
- Multi-slot install of multiple crush PVs on one machine beyond normal Portage version selection

## Decisions

### 1. Shared planner for outdated and update

**Choice:** One planning function produces lane targets, unique PVs, KEYWORDS membership, and gap status vs local ebuilds. `outdated` prints gaps; `update` applies them.

**Alternatives:** Planner only in `update` — rejected (`outdated` would lie). Separate ad-hoc logic — rejected (drift).

### 2. Lane matrix: arch × keyword tier

**Choice:** Four logical lanes:

| Lane id | Go ceiling | Label |
|---------|------------|--------|
| amd64-plain | max `dev-lang/go` PV with KEYWORDS containing bare `amd64` (not only `~amd64`) | `(dev-lang/go amd64)` |
| amd64-tilde | max with `~amd64` or bare `amd64` | `(dev-lang/go ~amd64)` |
| arm64-plain | max with bare `arm64` | `(dev-lang/go arm64)` |
| arm64-tilde | max with `~arm64` or bare `arm64` | `(dev-lang/go ~arm64)` |

Ignore `9999` / live ebuilds. Parse KEYWORDS from each non-live `go-*.ebuild` under `$PORTDIR/dev-lang/go`.

**Ceiling empty:** if no Go ebuild matches a tier/arch, that lane has no target (warn; do not invent).

### 3. Gentoo tree via portageq

**Choice:** `portageq get_repo_path / gentoo` then filesystem scan. Fail the Go plan (soft-warn for outdated / hard-fail or soft-skip with clear error for update—prefer hard-fail package when `update` was asked to refresh a Go package and tree is unreadable) if `portageq` or path fails.

**Alternatives:** Config key — out of scope. Hardcode `/var/db/repos/gentoo` — rejected (layout varies).

### 4. Upstream candidates and go_req probe

**Choice:**

- List comparable GitHub versions after tag-prefix strip (paginated tags and/or releases; prefer the same population used for “latest” plus range, not only `releases/latest`)
- For each candidate tag, fetch `go.mod` at configured subdirectory (HTTP: raw.githubusercontent.com or Contents API with token) and parse `go` line with existing `Update.Go.Version` helpers
- Cache `(owner, repo, tag, subdir) → go_req` within a process
- Per lane: `P = max { v | go_req(v) ≤ C }` among candidates with parseable go_req; if go.mod missing/unparseable at a tag, skip that tag for selection
- Newest-first early exit per ceiling is an optimization; correctness is max under constraint

**Alternatives:** Full clone per tag — too heavy for planning. Assume go_req monotonic binary search only — optional optimization later, not required.

### 5. Collapse to unique ebuilds + KEYWORDS assembly

**Choice:** Target ebuild set = unique PVs among successful lane Ps.

For each PV:

- `KEYWORDS` = space-joined `~arch` for every arch that has **any** lane targeting that PV (e.g. both amd64 lanes → `~amd64`; both arches → `~amd64 ~arm64`)
- Never emit bare `amd64` / `arm64` without tilde on overlay packages
- `BDEPEND` / vendor / assets: existing Go path for that PV’s tag

If all four lanes share one P → one ebuild with both arches as needed.

### 6. Exact-set package directory

**Choice:** After a successful Go package update plan apply, the package directory’s versioned `*.ebuild` files for that PN SHALL be exactly the target set (plus never manage `9999` if present—leave live ebuilds untouched if any). Delete managed non-target version ebuilds as part of apply (git rm / stage deletion).

**Rationale:** Operator asked for no historical leftovers.

### 7. Stdout / outdated line mapping

**Choice:**

- Each report line: `category/package vFROM -> vTO (dev-lang/go …)` when a lane label applies; collapsed single-lane-equivalent may omit label only when a single unique PV and a single logical transition is enough—prefer **always attaching the lane label for multi-lane plans**, and for pure single-PV packages one line without forcing four identical labels if all lanes share the same from→to (implementation may emit one line per distinct (from, to, label) or coalesce identical from→to with one label when only one PV exists—**spec: emit one success/outdated line per lane that has a gap or was applied**, with label always present for Go tree-lane lines)
- **Converge** (locals `{v1,v2}` → targets `{v3}`): lines `v1 -> v3` and `v2 -> v3` (with labels as applicable to which lanes the old ebuilds related to; if unknown, map each removed local to the new PV with labels of lanes that select the new PV)
- **Split** (local `{v1}` → `{v2,v3}`): `v1 -> v2` and `v1 -> v3` with respective labels
- **Refresh same shape:** pair by lane (each lane’s previous tip if identifiable, else package’s related local)

Practical algorithm for reporting:

1. Compute `oldSet` = numeric version ebuilds present before apply (non-9999)
2. Compute `newSet` = target PVs
3. For each lane with target `P` and label `L`:
   - `from` = if some ebuild in oldSet equals prior tip for that lane, use it; else if |oldSet|=1 use that; else if converging to P use each old that is not in newSet once…  
   **Locked UX examples take precedence:** converge many→one: every old not remaining maps to the one new; split one→many: the one old maps to each new; two→two refresh: one line per lane old_tip→new_P.

### 8. Commits: one per lane, coalesce same PV

**Choice:** Preferred commit unit is per lane that requires a **distinct tree mutation**. If lanes A and B share PV and a single ebuild write satisfies both, produce **one** signed commit for that PV (not two empty commits). Message remains `category/package: <pv>` (existing shape). Deletions of obsolete ebuilds are staged with the commit that converges/replaces them (typically the commit introducing the surviving PV(s); if multiple PV commits, stage deletions with the last commit of the package apply storm or with the commit that makes the exact set true—prefer **one package-final commit only if needed for prune-only**; simpler: after all PV upserts, if deletions remain, include them in the last lane commit of that package).

**Rationale:** User asked one per lane; git reality forbids double-committing identical trees.

### 9. Host Go and preflight

**Choice:** Unchanged host ≥ go.mod gate per vendor build. Preflight still only requires `go` on PATH for Go packages, not tree ceilings. Document that operators should install newest tree `~` Go they intend to support so all target PVs can vendor.

### 10. Module layout (implementation sketch)

| Concern | Placement |
|---------|-----------|
| portageq + go ebuild KEYWORDS → ceilings | e.g. `Update.Go.Tree` / `Update.Portage` |
| List GitHub versions | extend `Update.GitHub` |
| go.mod at ref | e.g. `Update.Go.ModFetch` |
| Plan lanes + exact set | e.g. `Update.Go.Lanes` |
| outdated / update wiring | `Update.Check`, `Update.Apply`, `app/Main` |
| KEYWORDS edit | `Update.EbuildEdit` |

Injectable IO for tests (mock tree, mock go.mod bodies, mock version lists).

### 11. Non-Go packages

Unchanged: latest-only fetch, single ebuild rename path, historical ebuilds left alone for `GitMvAndManifest`.

## Risks / Trade-offs

- [portageq / gentoo missing on non-Gentoo CI] → Unit-test pure planners with fixtures; integration tests mock `portageq`; document Gentoo host requirement for live Go update/outdated planning
- [GitHub rate limits listing tags + many go.mod GETs] → Reuse token; cache; paginate carefully; fail package with clear error
- [go_req non-monotonic] → Explicit max under constraint, not binary search assumption
- [Arch KEYWORDS divergence misunderstood by users] → Labels name `dev-lang/go` arch/tier, not package stability
- [Deleting historical ebuilds surprises] → Intentional; document in help/README if needed
- [Four assets publishes] → Costly but correct; skip publish when release already exists and hash matches (existing orphan/retry patterns apply)
- [Partial multi-lane failure] → Continue other lanes; exit 1 if any hard-fail; exact-set may be incomplete until retry—prefer fail closed on prune until all target PVs successfully applied, then prune in same storm after successes (do not delete old ebuilds until replacements are in place)

**Apply ordering:** For each package: compute plan → for each unique PV needing work (vendor+ebuild) in ascending or descending PV order → after all successful PV materializations for this run’s targets, delete obsolete ebuilds → Manifest as needed per mutation → commits per lane/coalesce rules. If any target PV hard-fails, do **not** prune ebuilds that would leave the package with zero installable tips if avoidable; leave prior ebuilds and hard-fail package with message.

## Migration Plan

1. Ship planner + outdated reporting first or together with update apply (prefer one change delivery).
2. First `update` on a Go package may delete older ebuilds and add multi-PV set—operator should expect multi-commit.
3. Rollback: revert code; multi-PV ebuilds already written remain valid Portage packages.
4. Operators without gentoo repo: Go outdated/update planning fails soft/hard as specified; non-Go commands unaffected.

## Open Questions

None blocking. Optional later: `--version` override; more arches; config tree path.
