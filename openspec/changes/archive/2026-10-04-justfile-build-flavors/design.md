# Design

## Context

See `proposal.md` for why. Cabal 3.16 already puts `-O0` in a `noopt/` directory and `-O2` in `opt/` inside one build directory. It does not do that for `--enable-coverage`, `--enable-debug-info`, or `-hiedir`. This package hardcodes `-hiedir=.hie/{lib,exe,test}` and `-fwrite-ide-info`, and `scripts/coverage` searches `dist-newstyle`. `hk.pkl` calls `cabal build all`, `./scripts/coverage`, and stan/weeder on `.hie/`. The executable keeps `-threaded -rtsopts -with-rtsopts=-N`.

## Goals / Non-Goals

**Goals:**

- One flavor helper owns build directory and Cabal flags. The justfile and `hk.pkl` both call it.
- Four flavors with stable flags so switching does not rebuild the others.
- Gate coverage is the debug flavor. Optimized coverage stays a separate recipe.
- Collected HIE for stan/weeder comes only from the release build, with library, executable, and test files in separate directories.
- `just run` forwards manager argv, including globals before the work command.

**Non-Goals:**

- Profiling, an `-O2` flavor, per-command work recipes, Cabal flags on `just build`, a `cabal list-bin` fast path, or OpenSpec recipes.
- Changing the manager's parser or baking `+RTS -xc` into the default runtime flags.
- Making `just check` install tools, or teaching the git hook to call `just`.

## Decisions

### 1. Flavor helper, not Cabal's optimization directories

`scripts/with-flavor <flavor> -- <cabal-args…>` runs Cabal from the repo root with that flavor's flags. `just` is not on the hook path. `hk.pkl` calls the helper and `./scripts/coverage`.

| Flavor | `--builddir` | Cabal flags |
|---|---|---|
| `dev` | `dist/dev` | `--disable-optimization --enable-debug-info=1` and the stack-provenance `-ghc-options` |
| `release` | `dist/release` | none beyond the project default (`-O1`) |
| `coverage-dev` | `dist/coverage-dev` | dev flags plus `--enable-coverage` |
| `coverage-release` | `dist/coverage-release` | `--enable-coverage` only |

Stack-provenance options, applied to every component of `dev` and `coverage-dev`: `-finfo-table-map` and `-fdistinct-constructor-tables`. One `--ghc-options` value is correct here because every component gets the same flags. It is the wrong tool for per-component `-hiedir`, which is why those paths leave the cabal file.

`cabal.project` `jobs` and `semaphore` still apply. The helper does not pass `--ignore-project`. A job cap stays in gitignored `cabal.project.local`.

Alternative considered: rely on `noopt/` versus the default directory, and use a separate `--builddir` only for coverage. Rejected. Debug info and coverage are not part of Cabal's path key, so two recipes that share an optimization level still overwrite each other. Four explicit build directories match the four flag sets.

### 2. HIE is copied out of the component build tree

Remove `-hiedir=.hie/lib`, `-hiedir=.hie/exe`, and `-hiedir=.hie/test` from the cabal file. Keep `-fwrite-ide-info` in the common stanza. On GHC 9.10 the `.hie` files land under `extra-compilation-artifacts/hie/` inside each component's object directory (library `build/` or `noopt/build/`, executable `x/…/<name>-tmp/`, test `t/…/<name>-tmp/`), with the module path preserved under that `hie/` directory. The executable and test `Main` modules stay in different component directories. The collector also accepts a `.hie` file sitting next to its `.hi` if a toolchain writes that older layout.

After a successful `dev` or `release` Cabal command, the helper deletes `dist/<flavor>/hie` and copies only `*.hie` into:

- `dist/<flavor>/hie/lib`
- `dist/<flavor>/hie/exe` (paths under the executable component)
- `dist/<flavor>/hie/test` (paths under the test component)

Relative module paths are preserved. Coverage flavors do not collect. If a full `build all` of dev or release succeeds and any of the three destinations is empty, collection fails.

Stan: `--hiedir=dist/release/hie/lib`. Weeder: `--hie-directory` for `lib`, `exe`, and `test` under `dist/release/hie`, still with `weeder.toml`. `just stan` and `just weeder` depend on the release build so the copy has run.

Alternative considered: point stan at the raw component directory. Rejected. Those directories also contain `.o` and `.hi`, and the collected tree is only `.hie` files. Alternative considered: keep passing `-hiedir` from the command line. Rejected. One command-line `-hiedir` applies to every component and would merge the two `Main` modules again.

### 3. Coverage script is the gate, on coverage-dev

`scripts/coverage` keeps the three Overall / Unit / Integration runs, the excludes, and the `coverage/` reports. Each Cabal test invocation goes through `with-flavor coverage-dev`. Mix and `.tix` discovery searches `dist/coverage-dev` instead of `dist-newstyle`.

`just coverage` with no arguments runs that script. `just coverage <pattern>` runs one `with-flavor coverage-dev -- test all` with tasty `-p` and does not write the three-run report. `just coverage-release` is `with-flavor coverage-release -- test all` for each of the three patterns the script already uses, or a thin wrapper that reuses the script's report logic with the flavor selected by an environment variable. Prefer one script and a `COVERAGE_FLAVOR` variable (default `coverage-dev`) so report logic is not forked. The gate and `just coverage` leave the variable unset. `just coverage-release` sets `COVERAGE_FLAVOR=coverage-release`.

`hk.pkl` coverage step stays `./scripts/coverage`. Its build step becomes `scripts/with-flavor release -- build all`.

### 4. Just recipes

Require `just` 1.55 or newer (the per-recipe `[positional-arguments]` attribute used for forwarding). Shebang recipes that forward arguments shift a single leading `--` away before exec.

| Recipe | Body |
|---|---|
| `run`, `build`, `test` | `with-flavor dev` |
| `run-release`, `build-release`, `test-release` | `with-flavor release` |
| `coverage` | `./scripts/coverage`, or one patterned test on `coverage-dev` |
| `coverage-release` | `COVERAGE_FLAVOR=coverage-release ./scripts/coverage` |
| `check` | `hk check` |
| `format` | `hk fix -S tools-preflight -S ormolu` |
| `hlint` | `hk check -S hlint --all` |
| `stan`, `weeder` | depend on `build-release`, then `hk check -S <step> --all` |
| `init` | `init-tools` then `init-hooks` |
| `init-tools` | `./scripts/install-dev-tools` |
| `init-hooks` | `hk install` |

`cabal run mndz-overlay-manager -- "$@"` is the run body, inside the flavor. No recipe is named `outdated`, `update`, `gencache`, `eclean`, `list`, or `github-token`. The first recipe is a `default` that runs `just --list`.

Diagnosing a gate failure is documented, not a new recipe: rerun `just coverage <pattern>`, and for a stack dump run the same flavor with `--test-options` including `+RTS -xc`. Default `-with-rtsopts=-N` stays.

### 5. Ignore and docs

Gitignore `dist/`. Keep ignoring `dist-newstyle/` and stop treating `.hie/` as the analysis tree (it may remain ignored so old checkouts do not suddenly show those files). README examples use `just run`. CONTRIBUTING and AGENTS list the recipes, the four flavors, `cabal.project.local` as the job cap, the `just` 1.55 prerequisite, and the coverage-failure debug note. AGENTS preferred gate command becomes `just check`, which still runs `hk check`.

## Risks / Trade-offs

- [Gate HPC percentages move from `-O1` to `-O0`] → No floors are enforced. `just coverage-release` regenerates an optimized report. CONTRIBUTING says the gate report is the debug flavor.
- [Debug coverage changes timing versus the old optimized coverage run, so some deadlocks may move] → Accepted. The gate is the build agents can debug. Optimized coverage remains available when a bug only shows up there.
- [Cabal's component path layout changes and the HIE copy picks the wrong bucket] → Collection fails closed when `lib`, `exe`, or `test` is empty after `build all`. Stan's path is the collected tree, so a bad copy fails the gate instead of analyzing stale `.hie/`.
- [`just` older than 1.55 drops shebang arguments] → CONTRIBUTING states the minimum. The helper is plain shell and does not depend on that just version.
- [Two full local build trees plus two coverage trees cost disk] → Only this package's objects are duplicated. The Cabal store is shared. `dist/` is gitignored.
- [`hk fix -S ormolu` skips a future fixer] → That is the point of `format`. The full fix hook is not the recipe.

## Migration Plan

1. Land the helper, cabal `-hiedir` removal, coverage script, `hk.pkl`, justfile, gitignore, and docs together so the hook and `just check` agree.
2. Existing `dist-newstyle/` and `.hie/` are unused after the first new build. Contributors may delete them. Nothing reads them once `hk.pkl` and the coverage script have moved.
3. Rollback is reverting those files. Flavor directories are disposable.

## Open Questions

None. Flavor flags, which coverage build the gate runs, and HIE collection are decided.
