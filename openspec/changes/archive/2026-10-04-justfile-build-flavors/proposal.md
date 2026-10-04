# Proposal

## Why

Contributors and agents rebuild the whole package when they switch between an ordinary build, a debug build, and a coverage run, because Cabal only isolates optimization level and this repo stores one shared HIE tree. Coverage runs are also where rare MVar deadlocks show up, and the optimized coverage binary is the one that cannot be diagnosed. A justfile should be the entry point, and the quality gate's coverage build should be the debug one.

## What Changes

- Add a repository `justfile` as the documented entry for building, testing, running the manager, coverage, and the quality shortcuts. `just run` forwards the manager's own arguments (globals before the subcommand). Short build/test/run recipes use the dev flavor. Release recipes are explicit.
- Isolate four Cabal flavors in separate build directories: dev (`-O0`, debug info, Haskell stack provenance), release (`-O1`), coverage-dev (dev flags plus coverage instrumentation), and coverage-release (`-O1` plus coverage instrumentation).
- Make coverage-dev the blocking coverage gate (`just check` / `hk check` / `just coverage`), so a failing gate run is a binary an agent can debug (`+RTS -xc` and a debugger). Keep coverage-release as an explicit non-gate recipe.
- Collect HIE from the non-coverage dev and release builds into per-flavor trees. Stan and weeder read only the release tree. Coverage builds do not write that tree.
- Point README, CONTRIBUTING, and AGENTS at these recipes, including how to debug a coverage-gate failure.

## Non-goals

- Profiling, cost-center builds, or a performance gate.
- An `-O2` flavor, per-command just wrappers (`just outdated`, `just update`, and the other work commands), or forwarding extra Cabal flags through `just build`.
- A fast path that skips Cabal's plan check and executes a previously built binary directly.
- OpenSpec recipes in the justfile.
- Changing work-command behavior, package-target resolution, or the manager's argument syntax.
- Numeric coverage floors, or keeping gate HPC percentages comparable to older optimized coverage reports.
- Auto-installing quality tools from `just check` or from git hooks.
- Replacing hk as the git hook. `just check` calls `hk check`.

## Capabilities

### New Capabilities

- `dev-task-runner`: Just recipes and build flavors for contributors and agents, including `just run` argument forwarding, dev as the short-name build, release as an explicit flavor, and which coverage flavor the gate runs.

### Modified Capabilities

- `git-hooks-quality-gates`: The non-coverage pipeline build is the release flavor. Stan and weeder read HIE collected from that build. The coverage step remains the documented coverage entrypoint, which is the debug coverage flavor, and coverage builds must not overwrite the release HIE tree.
- `test-coverage`: The documented gate coverage entrypoint builds the debug coverage flavor (unoptimized, with debug info and stack provenance). An optimized coverage entrypoint exists and is not the blocking gate. Report shape (Overall / Unit / Integration, no numeric floors) stays.
- `project-docs`: Contributor docs name `just test` and `just check` as the test and gate entries, and describe `cabal.project.local` as the job-cap that those recipes honor.

## Impact

- **Tooling:** new `justfile`, a shared flavor helper used by just and by `hk.pkl`, `scripts/coverage` pointed at the debug coverage build directory, HIE collection, `.gitignore` for flavor build trees. `just` becomes a system prerequisite next to hk. Quality-tool pins and `scripts/install-dev-tools` stay.
- **Cabal file:** drop the shared `-hiedir` paths; keep `-fwrite-ide-info`. Executable RTS flags stay.
- **Gate:** same step order. The non-coverage compile is release. The instrumented tests are coverage-dev, so gate HPC numbers will differ from previous `-O1` reports.
- **Docs:** `README.md` operator examples, `CONTRIBUTING.md` workflows, `AGENTS.md` preferred commands and the coverage-crash debug note.
- **Operator CLI:** unchanged. `just run` is a new way to invoke the same arguments.
