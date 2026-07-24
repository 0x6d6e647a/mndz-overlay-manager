## Context

Part 6 of 8. Living `cli-activity` currently requires retaining rows that end in soft-skip **or** hard-fail with a non-spinner failure/warning glyph, and a scenario treats soft-skip and hard-fail together. Apply tracking calls `mhFail` for all-soft-skip outcomes. Exit codes already ignore soft-skip for hard-fail folding.

## Goals / Non-Goals

**Goals:**

- Soft-skip terminal state is visually and API-distinct from hard-fail.
- Success still removes rows; panel clear semantics unchanged.
- Exit codes and `ApplyOutcome` policy unchanged.
- Specs updated so SoT matches the distinction.

**Non-Goals:**

- Full progress redesign, new CLI flags, log-level changes.
- Changing which situations are soft-skip vs hard-fail.

## Decisions

### D1: API — add `mhSkip`

**Choice:** Extend `MultiHandle` with `mhSkip :: PackageKey -> Text -> IO ()` (reason text). `noopMultiHandle` no-ops it. Apply tracking: all soft-skip → `mhSkip`; any hard-fail → `mhFail`; else success path.

**Rationale:** Explicit and testable; avoids overloading fail with a boolean.

### D2: Presentation

**Choice:** Retain skip rows until phase clear (same retention as fail rows) but use a distinct glyph/state from hard-fail (warning vs error, or skip-specific marker). When color is on, skip styling differs from hard-fail; when color is off, glyph/text still distinguishable.

**Rationale:** Matches operator need to see “did not update” without implying catastrophic failure.

### D3: Spec MODIFIED requirement

**Choice:** Rewrite the multi-progress bullet and scenarios so:

- success → remove row  
- soft-skip → retain with **skip/warning** presentation  
- hard-fail → retain with **failure** presentation  

Do not claim soft-skip uses failure chrome.

### D4: Outdated command

**Choice:** If outdated multi-progress uses the same handle terminal methods for package statuses that are not “success,” map appropriately (e.g. fetch error → fail; ok → success remove). Soft-skip is primarily an apply concept; outdated may only need API compatibility (noop or unused).

## Risks / Trade-offs

- **[Risk] Spec archive merge must keep full MODIFIED requirement text** → Mitigation: copy entire multi-progress requirement block and edit.
- **[Risk] Call sites forget to set mhSkip** → Mitigation: compile-driven record update; tests for apply tracking.
- **[Risk] Operators relied on “red” for skips** → Mitigation: still retained rows with reason text; only severity chrome changes.

## Migration Plan

1. Extend MultiHandle + pure multi state + render.
2. Wire Apply tracking.
3. Tests + cli-activity delta.
4. `hk check`; archive.

Rollback: git revert.

## Open Questions

None blocking — exact glyph characters chosen at implement time for terminal width safety.
