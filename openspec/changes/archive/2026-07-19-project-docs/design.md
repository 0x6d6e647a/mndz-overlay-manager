## Context

Product behavior is specified under `openspec/specs/` and exercised by code, tests, and in-binary help (`cli-help`). Repository markdown historically mixed operator onboarding with quality-gate bootstrap and was updated only when a change author remembered a docs task.

This change formalizes three document roles already chosen in content work:

| File | Audience | Content home |
|------|----------|--------------|
| `README.md` | Operators | Features/prereqs, build/run, configuration, commands |
| `CONTRIBUTING.md` | Contributors | Rules/standards, bootstrap, quality workflows |
| `AGENTS.md` | AI agents | Pointers + agent-specific process rules (thin) |

`cli-help` owns executable help UX. `git-hooks-quality-gates` owns hook/tool policy. Neither is the right place for “when to update README.”

## Goals / Non-Goals

**Goals:**

- Standing process capability (`project-docs`) with clear file roles, update triggers, same-change rule, and accuracy bar.
- Baseline retrofit: three markdown files match current CLI/config/quality reality at archive time.
- Going-forward rule: product/process surface changes update docs in the same OpenSpec change.
- Explicit consistency seam with CLI surface / `cli-help` without duplicating help scenarios.

**Non-Goals:**

- Automated enforcement in `hk check` / pre-commit (no doc-linter or grepping Parser.hs).
- Generating README from OpenSpec or `--help`.
- Full behavioral parity (exit-code matrices, apply internals, tree lanes) in operator docs.
- Historical backfill of archived changes’ docs tasks.
- Merging `project-docs` into `cli-help` or `git-hooks-quality-gates`.

## Decisions

### 1. Standalone capability `project-docs`

**Choice:** New process capability under OpenSpec, not a delta on hooks or help.

**Rationale:** Docs sync is process/agent contract, not runtime CLI behavior and not a binary quality gate. Cross-links to `cli-help` and `git-hooks-quality-gates` as peers.

**Alternatives:** Fold into `cli-help` (wrong for CONTRIBUTING); fold into hooks (not hook-enforced); AGENTS-only bullet (easy to skip).

### 2. File-specific trigger matrix

**Choice:** Update only the file whose surface changed:

| Surface change | Update |
|----------------|--------|
| Work command add/remove/rename; global options operators rely on; config path/keys; runtime tool requirements for operators; command usage narrative | `README.md` |
| Quality pipeline steps, bootstrap (`install-dev-tools` / hk), tool pin policy, contributor workflow | `CONTRIBUTING.md` |
| Agent workflow, OpenSpec process for agents, anti-patterns, preferred gate commands | `AGENTS.md` |
| Pure internal implementation with no operator/contributor/agent surface change | no docs obligation |

**Rationale:** Avoid ceremonial thrash of all three files on every product PR.

### 3. Same-change, not follow-up

**Choice:** Required docs updates land in the same change as the surface delta; definition of done includes them.

**Rationale:** Follow-up docs PRs rot under agent workflows; archive should not leave operator docs lying.

### 4. Accuracy ladder (L1–L3 required intent, not L4)

**Choice:**

- **L1:** No false statements (wrong keys, removed commands, legacy names).
- **L2:** Catalog complete for that file’s role (README: work commands + relevant globals + config keys + prereqs; CONTRIBUTING: pipeline/bootstrap accurate; AGENTS: pointers valid).
- **L3:** Documented examples use real subcommands, options, and config keys.
- **Not L4:** Full OpenSpec restatement forbidden as a requirement.

**Rationale:** Reviewable by humans/agents against Parser, config types, and gate specs without dual-maintaining every scenario.

### 5. Consistency with `cli-help` / implemented surface

**Choice:** Operator docs SHALL not contradict the implemented command catalog and global option surface; in-binary help remains authoritative for flag-level detail; README is narrative summary plus config/prereqs help cannot fully replace.

**Rationale:** Shared seam without merging specs or copying every help string into OpenSpec twice.

### 6. Baseline in this change, enforce forward after archive

**Choice:** This change includes content baseline + audit; after sync/archive, only deltas that touch surfaces re-touch docs. No reopening of archived changes.

**Rationale:** Day-zero main-spec “docs are accurate” should be true; going-forward cost stays proportional to surface change.

### 7. Soft enforcement via OpenSpec + AGENTS, not hk

**Choice:** Specs and tasks (and a thin AGENTS pointer) drive compliance; no CI gate in this change.

**Rationale:** Brittle name-grepping fails on intentional summary omissions; process bar is enough given OpenSpec-driven agents. Hard checks can be a later change if needed.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Process-only requirements ignored | Same-change rule in tasks templates/agent guide; explicit “done includes docs” |
| README grows into full OpenSpec | Non-goal L4; scenarios that say internal-only changes need no README update |
| Docs lag still possible without CI | Accept soft enforcement; optional future consistency check is separate |
| Over-triggering on every PR | Trigger matrix scoped to operator/contributor/agent surfaces |
| Dual ownership confusion with `cli-help` | Design decision 5: help owns flags detail; README owns narrative + config |

## Migration Plan

1. Land `project-docs` delta specs + design + tasks.
2. Apply: audit three markdown files against current CLI (`list` / `outdated` / `update`, globals, config keys, runtime tools) and quality gates; fix gaps; keep AGENTS thin with pointer to this process.
3. Sync delta into main `openspec/specs/project-docs/`.
4. Archive change.
5. Thereafter: any change that hits the trigger matrix updates the relevant file(s) in that change.

Rollback: remove or archive-revert the capability and docs policy text if abandoned; markdown content can remain as ordinary docs.

## Open Questions

None blocking. Optional later: cheap automated check that every work subcommand name appears under README Commands (not in this change).
