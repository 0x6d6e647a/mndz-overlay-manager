## Why

`hk fix` (preflight + ormolu inplace) auto-stages tracked Haskell files it reformats. That mutates the git index during ordinary work: agents and operators run `hk fix` to format, then find random `.hs` files staged without `git add`. Pre-commit already stashes unstaged hunks and restages files that were **already** in the index so a commit contains the formatted version — that path is correct and must stay.

## What Changes

- **`hk fix` does not stage.** The `fix` hook sets `stage = false`: ormolu still writes files in place; the index is left alone (including untracked files).
- **Pre-commit restage stays.** `fix = true`, `stash = "git"`, default `stage = true`: unstaged hunks stay out of the commit; already-staged files that ormolu rewrites are restaged.
- **`hk check` unchanged** (check-oriented ormolu; no inplace, no staging).
- **CONTRIBUTING** (and AGENTS only if the preferred-command line would otherwise be misleading) states that `hk fix` formats without `git add`.

**Not BREAKING** for overlay consumers. **Contributor-visible:** `hk fix` no longer silently `git add`s formatted tracked files.

### Non-goals

- Disabling pre-commit format/restage, changing `stash = "git"`, or adding `fail_on_fix`
- Changing the blocking pipeline (build, coverage, hlint, stan, weeder) or tool pins
- User-level `HK_STAGE` / `hkrc` policy; `--no-stage` as the only documented workaround instead of project config
- Grok/editor auto-stage behavior outside hk

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `git-hooks-quality-gates`: `hk fix` formats in place and SHALL NOT stage; pre-commit MAY restage already-staged files it formatted
- `project-docs`: CONTRIBUTING documents that `hk fix` does not mutate the index; pre-commit restage of already-staged formatted files remains

## Impact

- **Code/config:** `hk.pkl` `hooks["fix"].stage = false` only
- **Docs:** `CONTRIBUTING.md` (`hk fix` / edit-verify loop); `AGENTS.md` only if the existing `hk fix` one-liner would be wrong
- **Tests:** none required (hook config; `hk check` still green)
- **Operator/overlay:** none
