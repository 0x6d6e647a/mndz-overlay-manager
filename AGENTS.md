# Agent guide — mndz-overlay-manager

Instructions for AI coding agents working in this repository.

## Where to look

| Need | Document / path |
|------|-----------------|
| Product usage, build/run, configuration | [README.md](README.md) |
| Bootstrap, quality gates, standards, workflows | [CONTRIBUTING.md](CONTRIBUTING.md) |
| Product behavior (requirements) | `openspec/specs/` |
| Active change work | `openspec/changes/<name>/` (follow `tasks.md`) |
| When to update README / CONTRIBUTING / AGENTS | OpenSpec `project-docs` (`openspec/specs/project-docs/`) |

Prefer **[CONTRIBUTING.md](CONTRIBUTING.md)** for how to run tools and pass quality gates. Do not re-invent a parallel workflow.

**Preferred commands** (details and failure recovery in CONTRIBUTING):

```bash
hk check          # full gate — required before “done” / shipping
hk fix            # preflight + ormolu inplace only
./scripts/install-dev-tools   # if .tools/bin tools are missing
```

## Agent-specific rules

1. **Quality gates are mandatory.** Treat CONTRIBUTING’s pipeline as blocking. Do not skip with `--no-verify` or claim work is done without `hk check` (or the equivalent full pipeline) unless the user explicitly scoped narrower verification.
2. **Project-local tools only.** Use `.tools/bin/*` for ormolu, hlint, stan, and weeder. If a tool is missing, run `./scripts/install-dev-tools`. Do **not** invent auto-install inside hooks, call global PATH binaries as a workaround, or `cabal install` quality tools into `~/.local/bin` for this workflow.
3. **OpenSpec-driven implementation.** When an active change exists, implement from its `tasks.md`. Mark tasks complete only when the relevant gate is green. Keep proposal/design/tasks/spec artifacts updated if the design shifts. Product truth lives under `openspec/specs/` (and change deltas while a change is open).
4. **Keep project docs in sync.** If the change alters operator CLI/config, quality bootstrap/pipeline, or agent process, update the matching markdown file(s) in the **same** change per `project-docs`. Do not leave README/CONTRIBUTING/AGENTS for a follow-up. Do not re-host full command catalogs or pipeline tables in this file.
5. **Do not weaken static analysis casually.** Prefer fixing code over broadening `.stan.toml` excludes or `weeder.toml` roots. Do not leave scaffold / unused exports that weeder will flag without deliberately updating `weeder.toml` with justification—and only with an explicit user decision when weakening baselines.
6. **HIE must match sources.** Do not run stan/weeder without a recent successful `cabal build all`. After deleting modules, clear stale HIE if needed (`rm -rf .hie && cabal build all`).
7. **Keep tool pins in sync** if you change versions: both `cabal.project` and `scripts/install-dev-tools`. Do not commit `.tools/`, `.hie/`, or `dist-newstyle/`.
8. **No parallel hook stacks** (mise/pre-commit/lefthook, etc.) without an explicit design change. Do not lower `cabal-version` or drop HIE flags just to silence tools.
