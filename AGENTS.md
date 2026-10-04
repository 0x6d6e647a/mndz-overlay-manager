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
just check                    # full gate — required before “done” / shipping (runs hk check)
just format                   # preflight + ormolu inplace only (does not git add)
just coverage                 # coverage-dev tests + HPC reports (gate test step)
./scripts/install-dev-tools   # if .tools/bin tools are missing
```

A coverage failure from `just check` is the `coverage-dev` binary (`dist/coverage-dev`, unoptimized, with debug info and stack provenance). Rerun one test with `just coverage <pattern>`. For a runtime stack dump, run that same flavor with `+RTS -xc`:

```bash
./scripts/with-flavor coverage-dev -- test all --test-options='-p <pattern> +RTS -xc'
```

## Agent-specific rules

1. **Quality gates are mandatory.** Treat CONTRIBUTING’s pipeline as blocking. Do not skip with `--no-verify` or claim work is done without `just check` (which runs `hk check`) unless the user explicitly scoped narrower verification.
2. **Project-local tools only.** Use `.tools/bin/*` for ormolu, hlint, stan, and weeder. If a tool is missing, run `./scripts/install-dev-tools`. Do **not** invent auto-install inside hooks, call global PATH binaries as a workaround, or `cabal install` quality tools into `~/.local/bin` for this workflow.
3. **OpenSpec-driven implementation.** When an active change exists, implement from its `tasks.md`. Mark tasks complete only when the relevant gate is green. Keep proposal/design/tasks/spec artifacts updated if the design shifts. Product truth lives under `openspec/specs/` (and change deltas while a change is open).
4. **Keep project docs in sync.** If the change alters operator CLI/config, quality bootstrap/pipeline, or agent process, update the matching markdown file(s) in the **same** change per `project-docs`. Do not leave README/CONTRIBUTING/AGENTS for a follow-up. Do not re-host full command catalogs or pipeline tables in this file.
5. **Do not weaken static analysis casually.** Prefer fixing code over broadening `.stan.toml` excludes or `weeder.toml` roots. Do not leave scaffold / unused exports that weeder will flag without deliberately updating `weeder.toml` with justification—and only with an explicit user decision when weakening baselines. **Do not reintroduce a blanket weeder `root-modules` list** covering essentially the entire library; roots must stay entrypoint-oriented (`Main.main`, justified public roots only). **Do not casually expand `exposed-modules`** without a real need from the executable or test-suite (prefer `other-modules` for internals).
6. **HIE must match sources.** Do not run stan/weeder without a recent successful release build (`just build-release`, or the release step inside `just check`). Stan and weeder read `dist/release/hie/{lib,exe,test}/` (library, executable, and test files stay in separate directories). Coverage builds do not write that tree. After deleting modules, clear a stale release tree if needed (`rm -rf dist/release && just build-release`).
7. **Keep tool pins in sync** if you change versions: both `cabal.project` and `scripts/install-dev-tools`. Do not commit `.tools/`, `.hie/`, `coverage/`, `dist/`, or `dist-newstyle/`.
8. **No parallel hook stacks** (mise/pre-commit/lefthook, etc.) without an explicit design change. Do not lower `cabal-version` or drop HIE flags just to silence tools.
