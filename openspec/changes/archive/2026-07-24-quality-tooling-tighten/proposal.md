## Why

Stan Style/Warning/Performance checks are fully excluded, StrictData is unused, and small hygiene items remain (`!!` in gap-line pool selection, empty cabal synopsis/description). After structural refactors land, tightening static gates and polish should raise the floor without drowning the team in noise.

## What Changes

- Re-enable selected Stan severities (Performance and/or Warning) incrementally; fix findings or keep **narrow, justified** excludes only.
- Add `StrictData` or strategic bangs on hot records where cheap and safe (e.g. progress state, `PackageEntry`, plan-related records) without a project-wide rewrite.
- Replace `pool !! …` in gap-line construction with `NonEmpty` or explicit non-empty matching.
- Fill cabal `synopsis` and `description`.
- Confirm weeder roots still match `library-api-encapsulation` policy; adjust if needed.
- Update CONTRIBUTING (and `git-hooks-quality-gates` living requirements only if the blocking pipeline policy changes in a user-visible way).

## Program context

- **Part 8 of 8** of the post-audit quality program.
- **Apply order:** last, after major refactors and test modularization.
- **Depends on:** `pure-helpers-dedupe` … `test-suite-modularize` recommended complete; minimum after parts 1–3 so enabled checks do not fight mid-rename/split noise.

## Non-goals

- Perfect zero Stan excludes forever.
- Introducing new quality tools beyond the existing ormolu/hlint/stan/weeder set.
- Performance optimization projects unrelated to strictness hygiene.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `git-hooks-quality-gates`: Stan configuration is repository-owned; enabled checks must pass under the quality pipeline.
- `project-docs`: CONTRIBUTING documents the Stan baseline (enforced vs deferred severities/categories).

## Impact

- **Code:** various modules for StrictData/bangs and gap-line total rewrite; `.stan.toml`; `mndz-overlay-manager.cabal`; possibly `weeder.toml`.
- **Docs:** CONTRIBUTING for any new baseline expectations.
- **Gate:** `hk check` must stay green with the tightened config.
