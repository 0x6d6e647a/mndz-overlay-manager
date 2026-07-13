## Why

The project has no automated quality gates on commits: formatting, lint, compile/test, static analysis, and dead-code checks are manual and easy to skip (especially with AI-assisted edits). Introducing shared, blocking hooks improves consistency and catches regressions before they land.

## What Changes

- Add **hk** as the git hook orchestrator (`hk.pkl`) for pre-commit and manual `hk check` / `hk fix`.
- Manage quality tools (**ormolu**, **hlint**, **stan**, **weeder**) via **Cabal** only: pin versions in `cabal.project`, install into project-local `.tools/bin` (Option B).
- **Strict bootstrap**: if a required tool binary is missing, hooks fail with a clear message to run `scripts/install-dev-tools` (no auto-install, no mise).
- Blocking quality pipeline on commit/check:
  1. ormolu (format / fix)
  2. `cabal test all` (build + tests)
  3. hlint
  4. stan
  5. weeder
- Enable HIE generation for stan/weeder (`-fwrite-ide-info`, stable hie dir).
- Add supporting config: `weeder.toml`, optional `.hlint.yaml`, gitignore entries for `.tools/` and HIE output.
- Document bootstrap (`hk install`, tool install script).

## Capabilities

### New Capabilities

- `git-hooks-quality-gates`: Git hooks and project lint/check entrypoints that enforce format, tests, hlint, stan, and weeder using Cabal-managed tools under a strict install policy.

### Modified Capabilities

- (none — no existing product-command requirements change)

## Impact

- **New files**: `hk.pkl`, `cabal.project` (if absent), `scripts/install-dev-tools`, `weeder.toml`, optional `.hlint.yaml`, README/bootstrap notes.
- **Config**: `.gitignore` for `.tools/`, `.hie/` (or equivalent); GHC options for HIE on project components.
- **Developer workflow**: Requires system `hk` and a one-time (or after pin bump) `scripts/install-dev-tools`; commits blocked until all gates pass.
- **CI (optional follow-up)**: Same `hk check` can be reused later; not required for this change’s core scope.
- **No change** to application CLI behavior or library APIs.
