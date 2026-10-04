# Contributing

How to develop and contribute to **mndz-overlay-manager**.

For product usage (build, run, configuration), see **[README.md](README.md)**.  
AI coding agents should also read **[AGENTS.md](AGENTS.md)**.

## Rules and standards

1. **Do not skip quality gates.** Commits and “done” work must pass `just check` (which runs `hk check`, the same pipeline as pre-commit).
2. **Tools are project-local only.** Hooks use `.tools/bin/*`, never ambient `ormolu` / `hlint` / `stan` / `weeder` on `PATH`.
3. **Strict bootstrap.** If a tool is missing, hooks **fail** and instruct you to run `./scripts/install-dev-tools`. Hooks do not auto-install and do not fall back to global binaries.
4. **Keep tool pins in sync** when changing versions: `cabal.project` **and** `scripts/install-dev-tools`.
5. **Do not commit** `.tools/`, `.hie/`, `coverage/`, `dist/`, or `dist-newstyle/`.
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
| `justfile` | Recipes for build, test, run, coverage, and `just check` |
| `scripts/with-flavor` | Per-flavor build directory and Cabal flags |
| `cabal.project` | Package root, tool version constraints, multi-core build defaults |
| `scripts/install-dev-tools` | Installs tools; pins must match `cabal.project` |
| `weeder.toml` | Dead-code roots / root-modules |
| `.stan.toml` | Stan include/exclude baseline |
| `mndz-overlay-manager.cabal` | Components; `-fwrite-ide-info` in `common warnings` |

### Multi-core Cabal builds

Project Cabal builds default to **all host logical CPUs** and the **GHC jobserver semaphore**:

- `cabal.project` sets `jobs: $ncpus` and `semaphore: True` (package-level jobs + coordinated module-level parallelism).
- `$ncpus` is a Cabal token expanded on the machine that runs the build (laptops and high core-count hosts share the same file).
- Just recipes call Cabal through `scripts/with-flavor`, which does not pass `--ignore-project`, so `just build`, `just test`, `just check`, and the other build recipes inherit these settings.

**Job cap:** put a persistent override in gitignored `cabal.project.local` (for example `jobs: 8`). Just build recipes do not accept extra Cabal flags, so there is no per-invocation `-j` on `just build` or `just test`. The quality gate sees the same cap.

**`./scripts/install-dev-tools`** uses `--ignore-project`, so it does **not** read `cabal.project` or `cabal.project.local`. The script passes `-j --semaphore` explicitly so tool installs still use host-CPU parallelism.

### Build flavors

Each flavor has its own build directory, so switching flavors does not rebuild the others. Flags are fixed in `scripts/with-flavor`.

| Flavor | Directory | What it is | Recipes |
|--------|-----------|------------|---------|
| dev | `dist/dev` | `-O0`, debug info, stack provenance (`-finfo-table-map`, `-fdistinct-constructor-tables`) | `just build`, `just test`, `just run` |
| release | `dist/release` | Cabal's default optimization (level 1), no dev debug flags | `just build-release`, `just test-release`, `just run-release` |
| coverage-dev | `dist/coverage-dev` | Dev flags plus coverage instrumentation | `just coverage`, and the coverage step of `just check` |
| coverage-release | `dist/coverage-release` | Release optimization plus coverage instrumentation | `just coverage-release` (not part of the gate) |

Stan and weeder read HIE collected from the release build into `dist/release/hie/{lib,exe,test}/`. Coverage builds do not write that tree. There is no `-O2` flavor and no per-command recipe for work commands (`outdated`, `update`, and the others are arguments to `just run`).

## Developer onboarding

### Prerequisites

| Tool | Notes |
|------|--------|
| [GHC](https://www.haskell.org/ghc/) + [cabal-install](https://www.haskell.org/cabal/) | Project targets GHC **9.10.x** (see `ghc --version`) |
| [just](https://just.systems/) **1.55 or newer** | Task runner for build, test, run, coverage, and `just check`. System install; `./scripts/install-dev-tools` does not install it |
| [hk](https://hk.jdx.dev/) | Git hook runner (system install; not vendored in the repo) |
| Network | First-time tool install pulls from Hackage |

Optional: [GHCup](https://www.haskell.org/ghcup/) to install GHC and Cabal.

Quality tools are **not** on your global PATH for hooks. They live under **`.tools/bin`**, installed via Cabal.

### 1. Install project quality tools and git hooks

From the repository root:

```bash
just init
```

`just init` runs `./scripts/install-dev-tools`, then `hk install`. It does not build the manager, and it does not install `just`.

`./scripts/install-dev-tools` installs pinned versions of **ormolu**, **hlint**, **stan**, and **weeder** into `.tools/bin`.

- First run can take several minutes (`ghc-lib-parser` and friends are large); the script enables multi-core Cabal builds (`-j --semaphore`).
- The script sets `TMPDIR=.tools/tmp` so builds do not fill a small `/tmp` tmpfs.
- Re-run after changing version pins in `cabal.project` / `scripts/install-dev-tools`.
- If install fails with disk/tmp errors: ensure home disk has free space; do not rely on a 1G tmpfs `/tmp` for `ghc-lib-parser` builds.
- If install OOMs on a high core-count machine, cap jobs for that run (edit the script temporarily or set a lower concurrency in your user Cabal config).

`hk install --global` is hk’s machine-wide setup. With a global install, repos **without** `hk.pkl` are a no-op; this repo has `hk.pkl`, so hooks run here.

### 2. Confirm the pipeline

```bash
just check
```

All steps must pass before you commit (pre-commit runs the same gates, with ormolu allowed to fix already-staged files and restage them; unstaged hunks are stashed first so they are not pulled into the commit).

### Building and running the program

See **[README.md](README.md)** for commands, configuration, and how to build and run the CLI (without the quality-tool bootstrap above).

## Workflows

### Full quality pipeline (blocking)

Same order as `hk.pkl` / pre-commit:

| # | Step | Role / command |
|---|------|----------------|
| 0 | Preflight | `.tools/bin/{ormolu,hlint,stan,weeder}` must be executable |
| 1 | Format | `.tools/bin/ormolu --mode check` / `--mode inplace` |
| 2 | Build (HIE) | `scripts/with-flavor release -- build all` — non-coverage release flavor (`dist/release`). Collects HIE into `dist/release/hie/{lib,exe,test}/` |
| 3 | Coverage tests + reports | `./scripts/coverage` — debug coverage flavor `coverage-dev` (Overall, then Unit, then Integration) and HPC reports |
| 4 | Lint | `.tools/bin/hlint` on `*.hs` |
| 5 | Stan | `.tools/bin/stan --hiedir=dist/release/hie/lib` (config: `.stan.toml`) |
| 6 | Weeder | `.tools/bin/weeder --config=weeder.toml --hie-directory=dist/release/hie/lib --hie-directory=dist/release/hie/exe --hie-directory=dist/release/hie/test` |

Coverage is the **blocking test gate**, and that gate builds the **coverage-dev** flavor (unoptimized, with debug info and stack provenance). There is no separate uninstrumented `cabal test all` in the hook path. Stan and weeder always consume HIE from the release build (step 2), not from a coverage build. `just coverage-release` is not a pipeline step.

A failure of that gate is the `coverage-dev` binary. Rerun one test on the same flavor with `just coverage <pattern>`. For a runtime stack dump, pass `+RTS -xc` to that flavor:

```bash
./scripts/with-flavor coverage-dev -- test all --test-options='-p Overlay +RTS -xc'
```

`+RTS -xc` is not a default runtime flag. It needs the debug info and stack-provenance options coverage-dev already sets. Gate HPC percentages are from this unoptimized build; numeric floors are not enforced, and `just coverage-release` regenerates an optimized report when you want one.

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
just check     # full gate (runs hk check; same steps as pre-commit, check-oriented)
just format    # preflight + ormolu inplace only (does not git add)
```

Do not run stan or weeder without a recent successful release build (`just build-release`, or step 2 of `just check`). They read `dist/release/hie/`. Coverage builds must not be treated as the HIE source for analyzers.

### Day-to-day commands

```bash
just check                 # full gate (release build + coverage-dev + analyzers)
just format                # preflight + ormolu inplace; does not stage files
just test                  # uninstrumented dev-flavor suite
just test Unit             # tasty pattern on the dev flavor
just coverage              # coverage-dev reports (the gate's coverage step)
just coverage Overlay      # one pattern on the coverage-dev binary
just coverage-release      # optimized coverage reports; not the gate
hk run pre-commit          # exercise the pre-commit hook without committing

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
just test                  # full suite (uninstrumented dev flavor)
just test Unit             # unit isolation group only
just test Integration      # integration isolation group only
just test Overlay          # tasty pattern filter (domain subset)
just coverage              # gate coverage: coverage-dev tests + Overall/Unit/Integration reports
just coverage-release      # optimized coverage reports; does not replace coverage-dev products
```

Tasty’s `-p` / `--pattern` accepts a pattern over test names (see [tasty’s pattern syntax](https://github.com/UnkindPartition/tasty#patterns)). `just test <pattern>` passes that pattern through. Prefer `just coverage` or full `just check` before shipping; uninstrumented filters are for local iteration.

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
2. Format: `just format` or `.tools/bin/ormolu --mode inplace …` (`just format` does not `git add`; stage files yourself when you want them in a commit).
3. Tests: `just coverage` (or full `just check`). For a quick uninstrumented smoke: `just test`.
4. Fix hlint/stan/weeder findings; do not weaken configs without intent.
5. Re-run `just check` until green.
6. Mark OpenSpec tasks complete only when the relevant gate is green.

### If a hook or gate fails

| Symptom | What to do |
|---------|------------|
| `missing project tool: .tools/bin/...` | Run `./scripts/install-dev-tools` (or `just init` if hooks are also missing). `just check` does not install tools |
| ormolu wants a reformat | `just format` or `.tools/bin/ormolu --mode inplace path/to/File.hs` (`just format` does not stage) |
| tests / build fail | Fix compile/test errors; `just test` or `just coverage` locally |
| coverage gate fails | The binary is coverage-dev. Rerun `just coverage <pattern>`. For a stack dump, see the `+RTS -xc` example above |
| coverage report missing / script error | Ensure `hpc` is on PATH (ships with GHC); inspect `scripts/coverage` output; confirm `.tix` under `dist/coverage-dev/.../hpc/vanilla/tix/` |
| hlint hints | Apply suggestions or adjust code; default hlint must be clean |
| stan observations | Fix code; update `.stan.toml` only with intent (baseline excludes are deliberate) |
| weeder weeds (exit 228) | Remove dead code or adjust `weeder.toml` `roots` / `root-modules` with justification |
| weeder GHC/HIE mismatch | Rebuild with project GHC: `just build-release`; reinstall weeder via `./scripts/install-dev-tools` if the tool was built with the wrong GHC |
| Stale HIE after deleting modules | `rm -rf dist/release && just build-release` |

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
justfile             contributor recipes (just 1.55+)
scripts/with-flavor  Cabal flavor flags and build directories
scripts/install-dev-tools
scripts/coverage     HPC coverage entrypoint (coverage-dev by default)
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
| `dist/` | Flavor build trees (`dist/dev`, `dist/release`, `dist/coverage-dev`, `dist/coverage-release`) |
| `dist/release/hie/` | HIE collected from the release build for stan/weeder |
| `.hie/` | Legacy HIE tree; still ignored. Analysis reads `dist/release/hie/` |
| `dist-newstyle/` | Previous Cabal build tree; still ignored. Flavor builds do not use it |
