## Why

Multi-progress tracking reports all-soft-skip package outcomes through `mhFail`, so soft-skips (already latest, unconfigured, unsupported technique, etc.) look like failures in the activity panel. Exit codes already treat only hard-fail as failure; the chrome should match that distinction.

## What Changes

- Distinguish terminal **soft-skip** from **hard-fail** in multi-progress presentation.
- Add a dedicated skip path on the multi-progress handle (e.g. `mhSkip`) or an equivalent terminal skip state — soft-skip MUST NOT use the hard-fail path.
- Render skip distinctly from hard-fail (glyph and/or styling when color is on; short reason retained).
- Wire Apply package tracking so soft-skip → skip chrome, hard-fail → fail chrome, success → success removal behavior unchanged.
- Update tests for multi-progress pure state / apply tracking as needed.
- **Exit codes and apply outcomes stay the same** (`foldExitHardFail` still only hard-fail).

## Program context

- **Part 6 of 8** of the post-audit quality program.
- **Apply order:** after Apply split preferred; can follow parts 4–5; parallel-friendly with `test-suite-modularize` only if careful about test file ownership.
- **Depends on:** none hard; **recommended after** `split-apply-module`.

## Non-goals

- Redesigning the full progress panel layout or library choice.
- Changing soft-skip vs hard-fail product policy.
- Log severity redesign.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `cli-activity`: multi-progress retention rules currently lump soft-skip with hard-fail as a single failed/warning presentation; requirements and scenarios MUST distinguish skip vs hard-fail chrome while keeping success-row removal and panel clear semantics.

## Impact

- **Code:** `CLI.Progress`, Apply phase tracking (`applyPackagePhase1Tracked` or successor), tests for progress and apply.
- **Specs:** delta under `cli-activity`.
- **Ops:** TTY appearance for soft-skipped packages on `outdated`/`update` multi-progress.
