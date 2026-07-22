## Context

Go tree-lane planning (`Update.Go.Tree` + `Update.Go.Lanes`) already models four Gentoo `dev-lang/go` ceilings (amd64/arm64 × plain/tilde) and picks a package PV per lane from upstream `go.mod` requirements. Collapse then builds a unique ebuild set with KEYWORDS per PV.

Today `assembleKeywords` always emits `~arch` for every arch that has any lane on that PV. Specs explicitly forbid bare stable tokens. That matches “always testing overlay packages,” but it breaks the product meaning of plain lanes: a PV chosen because **stable** go is high enough is still invisible to pure stable `ACCEPT_KEYWORDS` unless the operator accepts `~`.

Real-world signal: after `dev-lang/go-1.26.4` stabilized (possibly per-arch over time), crush still carried `~` KEYWORDS and leftover older PVs whose KEYWORDS no longer match a full plain+tilde coverage story.

## Goals / Non-Goals

**Goals:**

- Make package KEYWORDS reflect **lane tier** so plain-lane targets are Portage-visible on stable profiles.
- Keep tilde-only targets keyworded `~arch` when only testing go admits that PV.
- Preserve multi-PV collapse, exact-set prune, content-fix, and apply/reuse paths; only change token assembly and equality expectations.
- Align tests and delta specs with the new assembly rule.

**Non-Goals:**

- Changing how go ceilings are computed (bare go still lifts both plain and tilde ceilings).
- Stabilizing or keywording non-Go packages; host Go gate; vendor/assets publish; md5-cache commit flow.
- Emitting both bare and tilde for the same arch on one ebuild.
- Automatically rewriting the live mndz-overlay repo in this change (operator re-runs `update` after the manager ships).

## Decisions

### 1. Per-arch tier-aware KEYWORDS assembly

**Decision:** For each planned PV and each arch in `{amd64, arm64}`:

1. If any **plain** lane for that arch targets the PV → emit bare `arch`.
2. Else if any **tilde** lane for that arch targets the PV → emit `~arch`.
3. Else omit the arch.

Token order remains stable and deterministic (prefer `amd64` then `arm64`, each once).

**Rationale:** Mirrors Gentoo visibility: bare satisfies stable and testing consumers; `~` is only needed when the version is testing-only for that arch. Same implication already used on the go side of the planner.

**Alternatives considered:**

- Keep always-`~` and document that operators must accept testing keywords → rejects the plain-lane product goal.
- Emit both `amd64` and `~amd64` when both lanes target → redundant in Portage; bare alone is enough.
- Map “all lanes on PV ⇒ `~` only if any tilde” → would leave plain consumers unserved when only plain targets (edge) or when both target and we wrongly prefer `~`.

### 2. Collapse still keys off lane list, not re-scanning arches alone

**Decision:** Extend assembly input from “set of arches” to “set of lanes” (or arches + tier flags) so plain vs tilde is known. `collapsePlannedEbuilds` already has `peLanes`; use `laneArch` + `laneTier` when building `peKeywords`.

**Rationale:** Minimal API surface change; no second pass over targets.

### 3. Content-fix and soft-skip use exact multiset KEYWORDS match (unchanged equality)

**Decision:** Keep `keywordsMatch` as exact multiset equality against the planned token list. When plan upgrades `~amd64` → `amd64`, existing ebuilds need content-fix (revbump when already local).

**Rationale:** Existing machinery already revbumps on KEYWORDS drift; no new reconcile path.

### 4. Apply writes whatever the plan says

**Decision:** `setKeywords` already writes arbitrary tokens; drop the “tilde only” apply scenario and require bare tokens when the plan includes them.

**Rationale:** Apply is a pass-through of planned KEYWORDS; the fix belongs in the planner.

### 5. Example end state (illustrative, not a hard-coded package rule)

When all four go ceilings equal `1.26.4` and max crush under that ceiling is `0.82.0` (with newer tags needing go `1.26.5` absent from Gentoo):

- Planned set: `{0.82.0}` with `KEYWORDS="amd64 arm64"`.
- Older PVs (e.g. `0.75.0-r1`) are extras and prune after successful materialization.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Overlay churn: many packages revbump KEYWORDS on first update | Expected one-time content-fix; reuse path avoids re-vendor when assets exist |
| Operators who relied on always-`~` + package.accept_keywords may see packages become stable-visible | Intended; bare keywords are the correct Portage story for plain-lane tips |
| Mixed bare/`~` on multi-PV packages confuses grepping | Documented in specs; order fixed; tests cover staggered cases |
| Mistaken bare keyword when only tilde lane targets | Assembly rule is plain-first; unit tests for tilde-only membership |

## Migration Plan

1. Land manager change with tests green (`hk check`).
2. Operators re-run `update` (or targeted package updates); content-fix + prune converge overlay KEYWORDS and exact sets.
3. No manager config migration.

Rollback: revert the manager change; overlay commits remain as git history (manual KEYWORDS revert if needed).

## Open Questions

- None blocking implementation. Token sort order (`amd64` before `arm64`) should match existing `assembleKeywords` / test expectations once updated.
