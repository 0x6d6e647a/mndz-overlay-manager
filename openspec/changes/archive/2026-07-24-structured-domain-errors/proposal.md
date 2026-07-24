## Why

Overlay validation, discovery, config, targets, and md5-cache already use structured error ADTs, but fetch/plan/apply/git paths mostly return `Either Text`. Callers and tests must match substrings; known failure classes (dirty paths, md5 gate, zero planned PVs, missing assets-path/token) cannot be exhausted at the type level.

## What Changes

- Introduce structured error types for known failure classes on the plan and apply paths, with pretty-printers to operator-facing `Text` at the CLI edge.
- Prioritize:
  - plan failures (no ceilings, no candidates / no non-live local, zero planned PVs, probe failures as appropriate)
  - apply unit failures already well-known (dirty involved paths, md5-cache gate, missing assets-path / GitHub token for DepsAndAssets, invalid package key)
- Convert internal call sites to return ADTs (or wrap existing `ApplyHardFail` messages via ADT → Text) without changing exit-code policy.
- Migrate selected tests from pure substring asserts to constructor (or pretty-print stability) asserts where practical.
- Keep operator-visible wording **clear and actionable**; prefer stable messages for scenarios that already pin text in living specs.

## Program context

- **Part 4 of 8** of the post-audit quality program.
- **Apply order:** after `split-apply-module`; may run in parallel with `library-api-encapsulation` once Apply is split.
- **Depends on:** `split-apply-module` (ADTs live next to stable module homes).

## Non-goals

- Full effect system / `ExceptT` stack rewrite.
- Typing every HTTP registry error in the first pass (optional stretch; Text at fetch edge is acceptable if scoped).
- Changing soft-skip vs hard-fail policy or exit codes.
- Progress chrome changes (part 6).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `update-apply`: Known hard-fail classes (dirty paths, md5 gate, missing assets-path/token, invalid key, zero planned PVs) MUST produce identifiable, actionable operator messages (supports structured internal errors with stable pretty-printing).

## Impact

- **Code:** Apply.* modules, Deps.Plan / runtime plan path, possibly Git ops; CLI printing in `app/Main.hs`.
- **Tests:** apply/plan failure cases; prefer ADT assertions where tests own the error type.
- **Specs:** only if operator-facing wording required by living scenarios changes.
