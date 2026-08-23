## 1. hk.pkl

- [x] 1.1 Set `hooks["fix"].stage = false`; leave pre-commit `fix = true` / `stash = "git"` and the check hook unchanged
- [x] 1.2 Confirm `hk validate` succeeds and `hk fix --plan` still runs the fix hook (ormolu inplace)

## 2. Docs

- [x] 2.1 `CONTRIBUTING.md`: `hk fix` formats in place and does not stage; pre-commit may restage already-staged files it formatted (`project-docs`)
- [x] 2.2 `AGENTS.md`: leave the `hk fix` one-liner unless it would imply index mutation

## 3. Quality gate

- [x] 3.1 `openspec validate --strict` for this change (and affected capabilities) clean
- [x] 3.2 `hk check` green
- [x] 3.3 After `hk fix`, formatted tracked files are not staged solely by that run (index unchanged vs pre-fix for those paths)
