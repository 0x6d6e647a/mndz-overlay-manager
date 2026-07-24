## Context

Part 4 of 8. After Apply is split, introduce structured errors for known plan/apply failure classes so callers stop relying solely on `Either Text` substring contracts. Overlay/Config/Discovery/Targets/Md5 already demonstrate the pattern (ADT + message function).

## Goals / Non-Goals

**Goals:**

- Typed failure classes for plan and key apply hard-fail reasons.
- Pretty-print to operator `Text` at CLI / `ApplyHardFail` edges.
- Preserve exit-code policy and soft-skip vs hard-fail outcomes.
- Prefer stable operator wording when living scenarios pin text.

**Non-Goals:**

- Full `ExceptT` / effect-system rewrite.
- Typing every HTTP/registry failure in the first pass.
- Changing product policy for when soft-skip vs hard-fail applies.

## Decisions

### D1: Pragmatic first slice

**In scope:**

1. **`PlanError`** (or equivalent) for: ceiling discovery failure, no non-live local candidates, zero planned PVs, and other plan-level failures already returned as `Left Text` from deps planning.
2. **`ApplyUnitError`** (name flexible) for: dirty paths, md5-cache gate, missing assets-path, missing GitHub token for assets publish, invalid package key — mapped into `ApplyHardFail` messages via pretty-printer.

**Deferred:** raw HTTP `Either Text` at GitHub/npm edges may remain Text until a follow-up.

### D2: Keep `ApplyOutcome` shape

**Choice:** Continue using `ApplyHardFail PackageKey Text Bool Bool` (or evolve the message field later). Structured errors convert to `Text` when constructing outcomes so Main and progress short reasons stay simple.

**Rationale:** Minimizes churn across progress and Main; still gains exhaustiveness inside Apply/Plan.

### D3: Module homes

**Choice:** Plan errors next to runtime/deps plan modules; apply unit errors in `Update.Apply` or `Update.Apply.Errors` after the split.

### D4: Test strategy

**Choice:** Where tests construct errors via ops fakes, assert pretty-printed messages **or** constructors if tests call pure pretty/error builders. Do not require rewriting every substring assert in one pass — migrate high-value cases.

### D5: Specs

**Choice:** No delta if operator strings and outcomes stay equivalent. If a pinned scenario must change, update living capability in the same change.

## Risks / Trade-offs

- **[Risk] Message drift breaks substring tests/specs** → Mitigation: copy existing strings into pretty-printers first; only then refine.
- **[Risk] Scope creep to all Text errors** → Mitigation: explicit deferred list in tasks.
- **[Risk] Double conversion noise** → Mitigation: convert once at the boundary to `ApplyHardFail` / log.

## Migration Plan

1. Add ADTs + pretty printers with strings matching current messages.
2. Convert plan path; convert apply gate paths.
3. Adjust tests; `hk check`.
4. Archive.

Rollback: git revert.

## Open Questions

- Whether `ApplyHardFail` should eventually store an ADT instead of `Text` — **out of scope** unless it proves trivial; default is Text payload + structured internal use.
