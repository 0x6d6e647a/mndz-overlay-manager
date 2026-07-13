# mndz-overlay-manager

Haskell CLI for managing a Gentoo overlay layout: list ebuilds, check for outdated packages, and related workflow.

**Stack:** Cabal · GHC 9.10.x · [hk](https://github.com/jdx/hk) for git hooks

## Prerequisites

| Tool | Notes |
|------|--------|
| [GHC](https://www.haskell.org/ghc/) + [cabal-install](https://www.haskell.org/cabal/) | Project targets GHC **9.10.x** (see `ghc --version`) |
| [hk](https://hk.jdx.dev/) | Git hook runner (system install; not vendored in the repo) |
| Network | First-time tool install pulls from Hackage |

Optional: [GHCup](https://www.haskell.org/ghcup/) to install GHC and Cabal.

## Build and run

```bash
cabal build all
cabal run mndz-overlay-manager -- --help
cabal test all
```

## Development bootstrap (quality tools + hooks)

Quality tools are **not** on your global PATH for hooks. They live under **`.tools/bin`**, installed via Cabal (strict policy: missing tools fail the hook; nothing auto-installs).

### 1. Install project quality tools

From the repository root:

```bash
./scripts/install-dev-tools
```

This installs pinned versions of **ormolu**, **hlint**, **stan**, and **weeder** into `.tools/bin`.

- First run can take several minutes (`ghc-lib-parser` and friends are large).
- The script sets `TMPDIR=.tools/tmp` so builds do not fill a small `/tmp` tmpfs.
- Re-run after changing version pins in `cabal.project` / `scripts/install-dev-tools`.

### 2. Enable git hooks

```bash
hk install
# or (hk’s recommended machine-wide setup):
hk install --global
```

With a global install, repos **without** `hk.pkl` are a no-op; this repo has `hk.pkl`, so hooks run here.

### 3. Confirm the pipeline

```bash
hk check
```

All steps must pass before you commit (pre-commit runs the same gates, with ormolu allowed to fix).

## Quality workflow

### What runs (all blocking)

| Step | Role |
|------|------|
| **tools-preflight** | Ensures `.tools/bin/{ormolu,hlint,stan,weeder}` are executable |
| **ormolu** | Format check (pre-commit / `hk fix` can rewrite) |
| **cabal-test** | `cabal build all && cabal test all` (also emits HIE under `.hie/`) |
| **hlint** | Lint suggestions must be clean |
| **stan** | Static analysis on HIE (see `.stan.toml` for baseline excludes) |
| **weeder** | Dead-code analysis (see `weeder.toml`) |

### Day-to-day commands

```bash
hk check          # full gate (same as pre-commit, check-oriented)
hk fix            # preflight + ormolu inplace only
hk run pre-commit # exercise the pre-commit hook without committing

# After editing pin versions:
./scripts/install-dev-tools
```

### If a hook fails

| Symptom | What to do |
|---------|------------|
| `missing project tool: .tools/bin/...` | Run `./scripts/install-dev-tools` |
| ormolu wants a reformat | `hk fix` or `.tools/bin/ormolu --mode inplace path/to/File.hs` |
| tests / build fail | Fix compile/test errors; `cabal test all` locally |
| hlint hints | Apply suggestions or adjust code; default hlint must be clean |
| stan observations | Fix or update `.stan.toml` only with intent |
| weeder weeds | Remove dead code or adjust `weeder.toml` roots / `root-modules` |

### Tool pins

Versions are listed in:

- `cabal.project` (`constraints:`)
- `scripts/install-dev-tools` (`CONSTRAINTS` array)

**Keep those two in sync** when bumping tools.

Current pins (verified on GHC 9.10.3): ormolu `0.8.1.1`, hlint `3.10`, stan `0.2.1.0`, weeder `2.10.0`.

### Generated / local-only paths (gitignored)

| Path | Purpose |
|------|---------|
| `.tools/` | Installed tool binaries + install temp dir |
| `.hie/` | HIE files for stan/weeder |
| `dist-newstyle/` | Cabal build tree |

## Project layout (short)

```
app/                 executable
src/                 library
test/                tests + fixtures
scripts/install-dev-tools
hk.pkl               hook configuration
weeder.toml          weeder roots
.stan.toml           stan baseline checks
cabal.project        package + tool pins
CONTRIBUTING.md      contributing notes
AGENTS.md            guidance for AI coding agents
```

## License

See [LICENSE](LICENSE) (AGPL-3.0-or-later).
