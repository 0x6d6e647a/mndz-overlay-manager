## Why

Operator and contributor documentation has been updated ad hoc (or skipped) while product behavior is specified under OpenSpec and enforced by code and `cli-help`. After splitting **README** (operator), **CONTRIBUTING** (contributor quality workflow), and **AGENTS** (thin agent guide), the project needs a standing process so those files stay accurate when the CLI, config, or quality pipeline changes—especially under agent-driven implementation.

## What Changes

- Introduce a **`project-docs`** process capability that defines:
  - Roles of `README.md`, `CONTRIBUTING.md`, and `AGENTS.md`
  - When each file must be updated (trigger matrix)
  - Same-change rule: docs land with the product/process change, not a follow-up
  - Accuracy bar: no false statements, complete operator/contributor surface summary, real examples; not full OpenSpec parity
  - Consistency seam with the implemented CLI surface and `cli-help` (without merging those specs)
- **Baseline retrofit** in this change: bring the three markdown files in line with current CLI, config, and quality-gate reality (session restructure + audit polish).
- **Going forward**: after archive, changes that touch operator or contributor surfaces update the relevant docs in the same change.
- No automated `hk` / git-hook enforcement of markdown accuracy in this change.

## Capabilities

### New Capabilities

- `project-docs`: Process rules for maintaining repository operator, contributor, and agent documentation in sync with product and quality-gate surfaces.

### Modified Capabilities

- (none) — `cli-help` and `git-hooks-quality-gates` remain the behavioral sources for help and hooks; `project-docs` references them as consistency peers, not requirement deltas.

## Impact

- **Docs**: `README.md`, `CONTRIBUTING.md`, `AGENTS.md` (baseline content + any audit fixes).
- **OpenSpec**: new main capability after sync/archive: `openspec/specs/project-docs/`.
- **Process**: future changes that alter commands, globals, config keys, runtime tool requirements, or the quality pipeline must update docs in-change; agents treat this as part of “done.”
- **Code / hooks**: no application code or `hk.pkl` changes required for this capability.
- **Not in scope**: generating docs from specs, full behavioral restatement of command specs in README, CI/grep gates for doc completeness.
