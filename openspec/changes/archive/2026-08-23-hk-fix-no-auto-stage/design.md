## Context

See `proposal.md` for motivation. `hk.pkl` `hooks["fix"]` has `fix = true` and inherits hk’s default `stage = true`, so ormolu `--mode inplace` is followed by auto-`git add` of tracked files it rewrote. `hooks["pre-commit"]` already has `fix = true` and `stash = "git"` (default `stage = true`). `hooks["check"]` uses ormolu `--mode check`. Hook `stage` is a Boolean on the hk Hook type (project `amends` Config.pkl ≥ 1.50). CONTRIBUTING advertises `hk fix` as “preflight + ormolu inplace only” without mentioning the index.

## Goals / Non-Goals

**Goals:**

- Make `hk fix` format-only (no index mutation) via project `hk.pkl`.
- Keep pre-commit stash + restage of already-staged formatted files.
- Document the split in CONTRIBUTING.

**Non-Goals:**

- Changing check/pre-commit pipeline steps, tool pins, or `fail_on_fix`.
- User `HK_STAGE` / `hkrc` as the project contract.
- Tests that invoke live `hk` against a throwaway git index (not in `hk check`).

## Decisions

### D1: `stage = false` only on the `fix` hook

**Choice:** `hooks["fix"] { fix = true; stage = false; … }`. Pre-commit keeps current `fix`/`stash`/`stage` defaults. Check stays check-oriented.

**Why:** hk’s auto-stage is per-hook. The surprise is the **manual** format entrypoint, not commit. Pre-commit restage is what makes `git commit` contain ormolu output after inplace rewrite of already-staged paths; stash keeps mixed staged/unstaged files from leaking unstaged hunks into the index.

**Alternatives:** `stage = false` on pre-commit too — rejected (commits would miss formatter output unless the operator restages). Rely on `hk fix --no-stage` in docs only — rejected (default still stages; agents run bare `hk fix`). Global `stage = false` in `hk.pkl` — rejected (would also disable pre-commit restage).

### D2: Docs in CONTRIBUTING; AGENTS only if the one-liner would lie

**Choice:** State on the `hk fix` / day-to-day / edit-verify lines that `hk fix` does not `git add`. Leave `AGENTS.md` if it still reads as “preflight + ormolu inplace only.” Mention that pre-commit may restage already-staged formatted files (so the two commands are not confused).

**Why:** `project-docs` quality-workflow surface is CONTRIBUTING. AGENTS is thin and already points at CONTRIBUTING.

**Alternatives:** Duplicate the full split in AGENTS — rejected (catalog).

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Operator expects `hk fix` to prepare the index for commit | CONTRIBUTING: format then stage yourself; pre-commit still formats staged files |
| Someone “fixes” `stage` back to default | Spec requirement + explicit `stage = false` in `hk.pkl` |
| `hk fix` still stages via CLI `--stage` or `HK_STAGE=1` | Allowed override; project default is no-stage |

## Migration Plan

Deploy is a `hk.pkl` + CONTRIBUTING commit. No data migration. Rollback is revert; `hk fix` auto-stages again.

## Open Questions

None.
