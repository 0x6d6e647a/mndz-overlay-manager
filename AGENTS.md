# Agent guide — mndz-overlay-manager

Instructions for AI coding agents working in this repository. Prefer this file for **how to run tools and pass quality gates**. Product behavior lives in `openspec/specs/` and change proposals under `openspec/changes/`.

## Hard rules

1. **Do not skip quality gates.** Commits and “done” work must pass `hk check` (or the equivalent full pipeline).
2. **Tools are project-local only.** Hooks use `.tools/bin/*`, never ambient `ormolu` / `hlint` / `stan` / `weeder` on `PATH`.
3. **Strict bootstrap.** If a tool is missing, **fail** and run `./scripts/install-dev-tools`. Do **not** invent auto-install inside hooks or call global binaries as a workaround.
4. **Keep tool pins in sync** when changing versions: `cabal.project` **and** `scripts/install-dev-tools`.
5. **Do not commit** `.tools/`, `.hie/`, or `dist-newstyle/`.

## One-time / clone bootstrap

From repo root, in order:

```bash
# 1. GHC + cabal available (ghc --version should be 9.10.x for this project)
# 2. hk available on PATH (system install)
./scripts/install-dev-tools    # populates .tools/bin (slow first time)
hk install                     # enable hooks if not already (or hk install --global)
hk check                       # must pass before shipping changes
```

If install fails with disk/tmp errors: the script already uses `TMPDIR=.tools/tmp`. Ensure home disk has free space; do not rely on a 1G tmpfs `/tmp` for `ghc-lib-parser` builds.

## Full quality pipeline (blocking)

Same order as `hk.pkl` / pre-commit:

| # | Step | Command / binary |
|---|------|------------------|
| 0 | Preflight | `.tools/bin/{ormolu,hlint,stan,weeder}` must be executable |
| 1 | Format | `.tools/bin/ormolu --mode check` / `--mode inplace` |
| 2 | Build + test | `cabal build all && cabal test all` (writes `.hie/`) |
| 3 | Lint | `.tools/bin/hlint` on `*.hs` |
| 4 | Stan | `.tools/bin/stan --hiedir=.hie` (config: `.stan.toml`) |
| 5 | Weeder | `.tools/bin/weeder --config=weeder.toml --hie-directory=.hie` |

**Preferred single entrypoint:**

```bash
hk check          # full gate
hk fix            # preflight + ormolu fix only
```

Do not run stan/weeder without a recent successful `cabal build all` (HIE must match sources and GHC).

## Edit → verify loop

1. Implement the change (prefer OpenSpec change tasks when one is active).
2. Format: `hk fix` or `.tools/bin/ormolu --mode inplace …`.
3. Tests: `cabal test all` (or full `hk check`).
4. Fix hlint/stan/weeder findings; do not weaken configs without an explicit user decision.
5. Re-run `hk check` until green.
6. Mark OpenSpec tasks complete only when the relevant gate is green.

## Failure recovery cheat sheet

| Error pattern | Action |
|---------------|--------|
| `missing project tool: .tools/bin/…` / install-dev-tools message | `./scripts/install-dev-tools` then retry |
| ormolu diff / mode check fail | `.tools/bin/ormolu --mode inplace <files>` or `hk fix` |
| Cabal compile/test fail | Fix code; `cabal build all && cabal test all` |
| hlint hints | Fix code (default: zero hints) |
| stan observations | Prefer fixing code; `.stan.toml` excludes are intentional baseline—do not broaden casually |
| weeder weeds (exit 228) | Remove dead code or update `weeder.toml` `roots` / `root-modules` with justification |
| weeder GHC/HIE mismatch | Rebuild with project GHC: `cabal build all`; reinstall weeder via `./scripts/install-dev-tools` if tool was built with wrong GHC |
| Stale HIE after deleting modules | `rm -rf .hie && cabal build all` |

## Config files agents must respect

| File | Role |
|------|------|
| `hk.pkl` | Hook steps and ordering |
| `cabal.project` | Package root + tool version constraints |
| `scripts/install-dev-tools` | Installs tools; pins must match `cabal.project` |
| `weeder.toml` | Dead-code roots / root-modules |
| `.stan.toml` | Stan include/exclude baseline |
| `mndz-overlay-manager.cabal` | Components; HIE flags in `common warnings` |

## What not to do

- Do **not** add mise/pre-commit/lefthook as a parallel tool path without a design change.
- Do **not** `cabal install` quality tools into `~/.local/bin` for “convenience” in this repo’s workflow.
- Do **not** disable pre-commit (`--no-verify`) to land work that fails gates.
- Do **not** lower `cabal-version` or drop HIE flags just to silence tools.
- Do **not** leave scaffold / unused exports that weeder will flag without updating `weeder.toml` deliberately.

## OpenSpec

- Active changes: `openspec/changes/<name>/`
- Main specs: `openspec/specs/`
- When implementing a change: follow that change’s `tasks.md`; keep artifacts updated if design shifts.

## Human docs

Broader narrative and tables: [README.md](README.md). Contributing pointer: [CONTRIBUTING.md](CONTRIBUTING.md).
