# Contributing

How to develop and contribute to **mndz-overlay-manager**.

For product usage (build, run, configuration), see **[README.md](README.md)**.  
AI coding agents should also read **[AGENTS.md](AGENTS.md)**.

## Rules and standards

1. **Do not skip quality gates.** Commits and “done” work must pass `hk check` (or the equivalent full pipeline).
2. **Tools are project-local only.** Hooks use `.tools/bin/*`, never ambient `ormolu` / `hlint` / `stan` / `weeder` on `PATH`.
3. **Strict bootstrap.** If a tool is missing, hooks **fail** and instruct you to run `./scripts/install-dev-tools`. Hooks do not auto-install and do not fall back to global binaries.
4. **Keep tool pins in sync** when changing versions: `cabal.project` **and** `scripts/install-dev-tools`.
5. **Do not commit** `.tools/`, `.hie/`, `coverage/`, or `dist-newstyle/`.
6. **Do not** add mise/pre-commit/lefthook as a parallel tool path without a design change.
7. **Do not** `cabal install` quality tools into `~/.local/bin` for “convenience” in this repo’s workflow.
8. **Do not** disable pre-commit (`--no-verify`) to land work that fails gates.
9. **Do not** lower `cabal-version` or drop HIE flags just to silence tools.
10. Prefer fixing code over broadening `.stan.toml` / `weeder.toml` without justification. Do not leave scaffold or unused exports that weeder will flag without updating `weeder.toml` deliberately.

### Tool pins

Versions are listed in:

- `cabal.project` (`constraints:`)
- `scripts/install-dev-tools` (`CONSTRAINTS` array)

**Keep those two in sync** when bumping tools.

Current pins (verified on GHC 9.10.3): ormolu `0.8.1.1`, hlint `3.10`, stan `0.2.1.0`, weeder `2.10.0`.

### Config files that define the pipeline

| File | Role |
|------|------|
| `hk.pkl` | Hook steps and ordering |
| `cabal.project` | Package root + tool version constraints |
| `scripts/install-dev-tools` | Installs tools; pins must match `cabal.project` |
| `weeder.toml` | Dead-code roots / root-modules |
| `.stan.toml` | Stan include/exclude baseline |
| `mndz-overlay-manager.cabal` | Components; HIE flags in `common warnings` |

## Developer onboarding

### Prerequisites

| Tool | Notes |
|------|--------|
| [GHC](https://www.haskell.org/ghc/) + [cabal-install](https://www.haskell.org/cabal/) | Project targets GHC **9.10.x** (see `ghc --version`) |
| [hk](https://hk.jdx.dev/) | Git hook runner (system install; not vendored in the repo) |
| Network | First-time tool install pulls from Hackage |

Optional: [GHCup](https://www.haskell.org/ghcup/) to install GHC and Cabal.

Quality tools are **not** on your global PATH for hooks. They live under **`.tools/bin`**, installed via Cabal.

### 1. Install project quality tools

From the repository root:

```bash
./scripts/install-dev-tools
```

This installs pinned versions of **ormolu**, **hlint**, **stan**, and **weeder** into `.tools/bin`.

- First run can take several minutes (`ghc-lib-parser` and friends are large).
- The script sets `TMPDIR=.tools/tmp` so builds do not fill a small `/tmp` tmpfs.
- Re-run after changing version pins in `cabal.project` / `scripts/install-dev-tools`.
- If install fails with disk/tmp errors: ensure home disk has free space; do not rely on a 1G tmpfs `/tmp` for `ghc-lib-parser` builds.

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

### Building and running the program

See **[README.md](README.md)** for commands, configuration, and how to build and run the CLI (without the quality-tool bootstrap above).

## Workflows

### Full quality pipeline (blocking)

Same order as `hk.pkl` / pre-commit:

| # | Step | Role / command |
|---|------|----------------|
| 0 | Preflight | `.tools/bin/{ormolu,hlint,stan,weeder}` must be executable |
| 1 | Format | `.tools/bin/ormolu --mode check` / `--mode inplace` |
| 2 | Build (HIE) | `cabal build all` — non-coverage build; emits HIE under `.hie/{lib,exe,test}/` for stan/weeder |
| 3 | Coverage tests + reports | `./scripts/coverage` — `cabal test all --enable-coverage` (Overall, then Unit, then Integration) and HPC reports |
| 4 | Lint | `.tools/bin/hlint` on `*.hs` |
| 5 | Stan | `.tools/bin/stan --hiedir=.hie/lib` (config: `.stan.toml`) |
| 6 | Weeder | `.tools/bin/weeder --config=weeder.toml --hie-directory=.hie/lib --hie-directory=.hie/exe --hie-directory=.hie/test` |

Coverage is the **blocking test gate**. There is no separate uninstrumented `cabal test all` in the hook path. Stan and weeder always consume HIE from the non-coverage build step (step 2), not from coverage-flagged objects.

**Phase 1:** the coverage step fails only if instrumented tests fail or required reports cannot be produced. **Numeric coverage floors / ratchet baselines are not enforced yet** (measure first; floors are a follow-up once summary numbers exist).

#### Stan baseline

`.stan.toml` is the committed include/exclude baseline. Intent (see comments in that file for per-inspection notes):

| Class | Status |
|-------|--------|
| **Error** anti-patterns | Enforced |
| **Performance** | Enforced, with narrow justified excludes for `STAN-0206` (non-strict fields / package-wide StrictData deferred) and `STAN-0208` (`Text` length; domain stays on `Text`) |
| **Style** | Deferred |
| **Warning** | Deferred |
| **Infinite** category | Deferred |

Prefer fixing new findings over widening excludes. When you deliberately change the baseline, update `.stan.toml` comments and this table in the same change.

**Preferred single entrypoint:**

```bash
hk check          # full gate (same as pre-commit, check-oriented)
hk fix            # preflight + ormolu inplace only
```

Do not run stan/weeder without a recent successful non-coverage `cabal build all` (HIE must match sources and GHC). Coverage builds use a separate Cabal plan and must not be treated as the HIE source for analyzers.

### Day-to-day commands

```bash
hk check          # full gate (build + coverage + analyzers)
hk fix            # preflight + ormolu fix only
hk run pre-commit # exercise the pre-commit hook without committing

./scripts/coverage   # instrumented tests + HPC reports only

# After editing pin versions:
./scripts/install-dev-tools
```

### Tests

The test suite is a **tasty** harness under `test/` with domain modules (`test/Test/*.hs`) and a thin `test/Main.hs`. Fixtures live in `test/fixtures/`.

Top-level tasty groups are **`Unit`** and **`Integration`** (isolation levels for coverage attribution):

| Level | Meaning |
|-------|---------|
| **Unit** | Single library concern; no multi-step apply/plan/commit spine; I/O limited to small committed fixtures or pure in-memory behavior. Property tests (QuickCheck) count as Unit technique. |
| **Integration** | Multi-module workflow; temporary overlay mutation; `ApplyEnv` / `PlanOps` / runners / multi-phase behavior. |
| **Overall** | Full suite (union used for the primary human markup and Overall summary row). |

```bash
cabal test all                                    # full suite (uninstrumented; local iteration)
cabal test all --test-options='-p Unit'           # unit isolation group only
cabal test all --test-options='-p Integration'    # integration isolation group only
cabal test all --test-options='-p Overlay'        # tasty pattern filter (domain subset)
./scripts/coverage                                # gate-equivalent: coverage-enabled tests + reports
```

Tasty’s `-p` / `--pattern` accepts a pattern over test names (see [tasty’s pattern syntax](https://github.com/UnkindPartition/tasty#patterns)). Prefer `./scripts/coverage` or full `hk check` before shipping; uninstrumented filters are for local iteration.

### Coverage reports

| Artifact | Path |
|----------|------|
| Machine summary (Overall / Unit / Integration) | `coverage/summary.json` |
| Human HPC markup (Overall) | `coverage/html/` |
| Saved tix / XML | `coverage/tix/`, `coverage/xml/` |

Metrics are HPC-native: **expressions**, **alternatives**, and **booleans**. Scored modules are product library code under `src/` (and executable modules when present in the map). **`Update.Apply.TestSupport`** is excluded from the product denominator (scaffolding); the exclude list lives in `scripts/coverage` and should stay in sync with this note.

Generated coverage output is **gitignored** — do not commit HTML, `.tix`, or summary files. There is no committed floor/baseline file in phase 1.

### Edit → verify loop

1. Implement the change (prefer OpenSpec change tasks when one is active).
2. Format: `hk fix` or `.tools/bin/ormolu --mode inplace …`.
3. Tests: `./scripts/coverage` (or full `hk check`). For a quick uninstrumented smoke: `cabal test all`.
4. Fix hlint/stan/weeder findings; do not weaken configs without intent.
5. Re-run `hk check` until green.
6. Mark OpenSpec tasks complete only when the relevant gate is green.

### If a hook or gate fails

| Symptom | What to do |
|---------|------------|
| `missing project tool: .tools/bin/...` | Run `./scripts/install-dev-tools` |
| ormolu wants a reformat | `hk fix` or `.tools/bin/ormolu --mode inplace path/to/File.hs` |
| tests / build fail | Fix compile/test errors; `cabal test all` or `./scripts/coverage` locally |
| coverage report missing / script error | Ensure `hpc` is on PATH (ships with GHC); inspect `scripts/coverage` output; confirm `.tix` under `dist-newstyle/.../hpc/vanilla/tix/` |
| hlint hints | Apply suggestions or adjust code; default hlint must be clean |
| stan observations | Fix code; update `.stan.toml` only with intent (baseline excludes are deliberate) |
| weeder weeds (exit 228) | Remove dead code or adjust `weeder.toml` `roots` / `root-modules` with justification |
| weeder GHC/HIE mismatch | Rebuild with project GHC: `cabal build all`; reinstall weeder via `./scripts/install-dev-tools` if the tool was built with the wrong GHC |
| Stale HIE after deleting modules | `rm -rf .hie && cabal build all` |

### OpenSpec

Product behavior is specified under OpenSpec:

- Main specs: `openspec/specs/`
- Active changes: `openspec/changes/<name>/`
- When implementing a change: follow that change’s `tasks.md`; keep artifacts updated if design shifts.
- **Documentation sync** (`project-docs`): when a change alters the operator CLI/config surface, quality pipeline/bootstrap, or agent process, update the relevant of `README.md` / `CONTRIBUTING.md` / `AGENTS.md` **in the same change**. Policy: `openspec/specs/project-docs/`.

### Project layout (short)

```
app/                 executable
src/                 library
test/                tasty suite: Main.hs (Unit/Integration groups), Test/* modules, fixtures/
scripts/install-dev-tools
scripts/coverage     HPC coverage entrypoint (gate test step)
coverage/            generated reports (gitignored)
hk.pkl               hook configuration
weeder.toml          weeder roots
.stan.toml           stan baseline checks
cabal.project        package + tool pins
openspec/            product specs and change proposals
README.md            build, run, configuration
AGENTS.md            guidance for AI coding agents
```

### Generated / local-only paths (gitignored)

| Path | Purpose |
|------|---------|
| `.tools/` | Installed tool binaries + install temp dir |
| `.hie/` | HIE files for stan/weeder |
| `dist-newstyle/` | Cabal build tree |
