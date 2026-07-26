## Context

mndz-overlay is an unstable personal overlay. **Policy target (GURU-aligned):** packages SHALL be keyworded with tilde only (`~amd64`, not bare `amd64`).

GURU documents this explicitly ([Project:GURU § Rules](https://wiki.gentoo.org/wiki/Project:GURU#Rules), package requirement 7.2):

> Packages in GURU are to have ~arch keywords. Stable keywords must not be used, with the exception of special kinds of packages that always use stable keywords via eclasses (e.g. acct-\* packages).

Science overlay operationalizes the same contract for users (`*/*::science ~${ARCH}`). mndz has no arch-team stabilization process, so bare KEYWORDS claim a maturity the overlay does not provide.

**Current manager behavior** (from archived `go-lane-keywords-plain-bare`): shared `assembleKeywords` maps plain-lane membership → bare arch and tilde-only → `~arch`, so pure stable `ACCEPT_KEYWORDS` can see plain-lane tips. That conflates two axes:

```
Axis A — runtime ceilings (KEEP)
  plain/tilde on go|rust|nodejs|bun-bin → which package PV each lane selects

Axis B — package KEYWORDS token form (CHANGE)
  today:  plain membership → bare token on the *package*
  target: any membership   → always ~token on the *package*
```

Live mndz-overlay inventory (bare major-arch tokens present):

| Package | Ecosystem | Action |
|---------|-----------|--------|
| `dev-db/dolt` | Go | revbump all-tilde |
| `dev-db/badger` | Go | revbump all-tilde |
| `dev-util/beads` | Go | revbump all-tilde |
| `dev-util/crush` | Go | revbump all-tilde |
| `dev-util/mise` | Cargo | revbump all-tilde |
| `dev-util/hk` | Cargo | revbump all-tilde |
| `dev-util/usage` | Cargo | revbump all-tilde |
| `dev-util/openspec` | npm | revbump all-tilde |

Already compliant (no revbump for KEYWORDS alone): `opencode`, `ralph-tui`, `bun-bin`, `deno-bin`, `grok-build-bin` (`-* ~arch` is fine).

## Goals / Non-Goals

**Goals:**

- Manager always writes **tilde** KEYWORDS tokens for **all** `DepsAndAssets` planned/written ebuilds for every arch that has lane membership.
- One shared assembly rule (no Go-only branch).
- Plain vs tilde **lanes** still select which package PV and which arches appear.
- Revision-bump **every** current overlay ebuild that has any bare KEYWORDS arch token (inventory above).
- Align delta specs (`runtime-lanes`, `go-tree-lanes`, `go-vendor-assets`) with the shared rule.

**Non-Goals:**

- Changing Gentoo/runtime ceiling discovery.
- Seeding packages or policy additions.
- Re-touching already-tilde packages solely for this change.
- Overlay-wide static scanner as a hard gate (manager plan/write is the enforcement surface).
- `acct-*`-style stable exceptions (none in mndz today).

## Decisions

### 1. Full-overlay scope (shape B)

**Decision:** This change is whole-overlay policy, not Go-only.

- Manager: all ecosystems that use lane KEYWORDS assembly.
- Overlay: all bare KEYWORDS ebuilds in the inventory (Go + Cargo + npm).

**Rationale:** User chose GURU `~*` as the policy; leaving mise/hk/usage/openspec bare would leave the tree non-compliant and the manager would reintroduce bare on next Cargo/npm plan if assembly stayed tier-aware for token form.

### 2. Semantics after change

```
Lane membership (unchanged):
  plain amd64 lane targets PV X  →  arch amd64 is in KEYWORDS for X
  tilde amd64 only targets PV Y  →  arch amd64 is in KEYWORDS for Y

Token form (new, all DepsAndAssets):
  any membership for arch A on PV  →  always emit ~A  (never bare A)
```

Preserve `-*` if present in donor/bin packages; do not invent bare tokens. Strip/replace bare arch tokens with `~arch` when rewriting from plans.

### 3. One shared helper

**Decision:** Change `assembleKeywords` (or its successor used by collapse for all ecosystems) so every included arch is `~arch`. Do not keep a plain→bare path for any ecosystem.

**Rationale:** Collapse already goes through one helper; Go-only branching would re-split policy and recreate the inventory gap for Cargo/npm.

### 4. Spec updates

- **MODIFIED** `runtime-lanes` “Collapse KEYWORDS across all runtime arches” → tilde-only for **all** ecosystems (not Go-special-case).
- **MODIFIED** `go-tree-lanes` “Unique ebuild set and KEYWORDS assembly” → tilde-only; plain/tilde still select PVs.
- **MODIFIED** `go-vendor-assets` “Overlay KEYWORDS for multi-PV Go packages” → tilde-only write rule.
- Cargo/npm/Bun inherit via `runtime-lanes` + shared assembly; no separate bare/tilde product rule. Bun already expected overlay tilde convention.

### 5. Overlay migration

For each package in the bare inventory:

1. Revision-bump (`-rN`) or content-edit next revision.
2. Set KEYWORDS to all-tilde form of the **existing** arch set (preserve which arches were listed; only force tilde on each arch token). Example: `amd64 arm64 ~loong` → `~amd64 ~arm64 ~loong`.
3. Manifest / md5-cache / signed commit as usual (manual or manager path if available).

Order: manager can land first (prevents re-borking) or overlay revs first then manager; prefer manager + tests green, then overlay revs, then spot-check.

### 6. Tests

Update unit/integration tests that expect bare `amd64`/`arm64` for plain-lane plans (any ecosystem) to expect `~amd64` / `~arm64`. Keep scenarios that distinguish plain vs tilde **lane selection of PV** (staggered multi-PV still valid; all ebuilds use tilde tokens).

### 7. Consumer contract

Operators of `::mndz` should accept testing keywords for the repo, e.g.:

```
*/*::mndz ~amd64
```

(or global `ACCEPT_KEYWORDS="~amd64"`). Same pattern as science/GURU consumers. No manager CLI change required; optional one-line note only if operator docs already describe overlay consumption (not required by project-docs if README stays manager-only).

## Risks / Trade-offs

- **[Risk]** Pure stable profiles lose visibility without accept_keywords → **Mitigation:** intended GURU-like contract; document for consumers of the overlay.
- **[Risk]** One-time revbump churn across eight packages → **Mitigation:** expected; single migration pass.
- **[Risk]** Token set wider than amd64/arm64 (loong, macos, …) → **Mitigation:** preserve arch set, only tilde-ize bare tokens; do not drop arches.
- **[Risk]** Tests and content-fix equality expect exact KEYWORDS multisets → **Mitigation:** update expectations; first plan after change content-fixes any leftover bare if revs lag.

## Migration Plan

1. Land manager shared KEYWORDS assembly + tests (`hk check`).
2. Revision-bump all bare inventory ebuilds in mndz-overlay (Go + Cargo + npm).
3. Spot-check KEYWORDS lines: no bare arch tokens on managed packages; `-*` + `~` bins unchanged.
4. Optional: re-run manager `update` / content-fix path to confirm plan KEYWORDS stay tilde.

Rollback: revert manager assembly; overlay commits remain in git history (manual KEYWORDS revert if needed).

## Open Questions

- None blocking. Inventory should be re-checked at implement time in case new bare ebuilds appear.
