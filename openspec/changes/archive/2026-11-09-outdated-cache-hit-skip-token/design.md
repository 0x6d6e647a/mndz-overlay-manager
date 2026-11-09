# Design

## Context

`runOutdated` and `runUpdate` both call `needsLiveGitHubApi` before `prepareGitHubToken`. For a DepsAndAssets package, `depsNeedsLive` treats a usable check-cache plan as live when `planNeedsWork` is true, and also when the overlay-provider latest entry is missing. `update` needs the first of those, because a needs-work plan is followed by an assets release lookup. `outdated` does not. Its check path serves a usable plan hit without another deps-plan fetch. The extra `api.github.com` reads on `outdated` are the provider latest miss and `previewHypothetical` after ceilings change. See proposal.md for why the prompt is wrong.

## Goals / Non-Goals

**Goals:**

- `outdated` decrypts only when a selected package will actually call `api.github.com`.
- The ceiling branch that decides `previewHypothetical` is one helper, shared by the check path and the outdated prompt decision.
- `update` keeps the current `needsLiveGitHubApi` result, including a prompt when a cached plan still needs work.

**Non-Goals:**

- Teaching `update` to prompt for the plan-phase hypothetical read that runs while the on-disk consumer plan is satisfied and both cache entries are valid.
- Storing hypothetical plans in the check cache.

## Decisions

### Split the live-GitHub decision by command

Add a mode argument to the existing lookup rather than a second copy of fingerprint and cache lookup. `LiveForUpdate` keeps today's `depsNeedsLive` answer: usable-plan miss, unusable Cargo snapshot, `planNeedsWork` (including a local content-assessment failure), or provider latest miss. `LiveForOutdated` uses the same miss and provider-latest rules, and does not treat `planNeedsWork` or a local content-assessment failure as live.

`app/Main.hs` passes `LiveForOutdated` from `runOutdated` and `LiveForUpdate` from `runUpdate`. `prepareGitHubToken` stays a pure function of that boolean.

Alternative: delete `planNeedsWork` from the shared predicate and let `update` prompt later in `resolveAssetsGitHub`. That moves the `update` password to after plan and leaves the plan-phase provider fetch on a cold latest entry without a token. Rejected.

Alternative: a wholly separate outdated walker. Rejected. The miss rules (TTL, fingerprint, provider fingerprint, Cargo snapshot usability, `--refresh`) would drift.

### Predict the hypothetical plan locally

When the consumer plan is a usable hit and the provider latest is also a hit, `outdated` already has both values. Compare ceilings with the same pure step the check uses (`overlayCeilingPlan`, then the "provider is in the selection and is not GitMv-outdated" shortcut). Entering `previewHypothetical` is a live read, even if plan-delta later does not hold, because that plan runs before the delta check. Unchanged ceilings, or ceilings that change while the selected provider is not GitMv-outdated, are not a live read.

If the provider directory or its metas cannot be read, the check fail-closes without a GitHub call once the provider latest is cached. The prompt decision follows that: no decrypt. A missing provider latest entry is already live via the existing miss check, so this local compare is skipped.

GitMv packages stay on `lookupLatest` alone. A non-GitHub source stays quiet. `--refresh` still forces the stored-plan and latest lookups to miss.

### One branch helper

Lift the "will this check call `previewHypothetical`?" condition out of `applyOverlayBlockIndication` and use it from the outdated mode. The check path keeps performing the fetch. The prompt path only evaluates the condition against the cached provider latest.

Alternative: re-implement the branch inside `depsNeedsLive` and leave the check as it is. Rejected. The two copies are the drift that would prompt with no call, or call with no token.

## Risks / Trade-offs

- [Prompt and check disagree about ceilings] → One helper owns the branch. Tests cover unchanged ceilings, changed ceilings with the provider selected and not outdated, and changed ceilings that enter the hypothetical plan.
- [An `update` edit "simplifies" both modes] → `LiveForUpdate` is the path that still returns true for a needs-work plan hit. A unit test locks that answer.
- [Ceiling compare does local tree IO before the password] → It runs only for a Bun consumer whose provider latest is already cached. No `api.github.com` call is added.
- [Satisfied Bun consumer, both hits, provider selected and behind] → `outdated` prompts, because the hypothetical plan is a live read. `update` in the narrower satisfied-plan case stays on its current predicate and can still fetch that plan before unlock. That hole is unchanged.

## Migration Plan

No cache schema, config, or flag change. Operators see `outdated` stop asking for the wrap password on a full hit. Rollback is reverting the commit. README text ships in the same change.

## Open Questions

None. The command split, the per-selection miss rule, and the Bun extra-read rule are fixed in the specs.
