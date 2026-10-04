# Tasks

## 1. Flavor helper and HIE collection

- [x] 1.1 Add `scripts/with-flavor` with the four flavors from `design.md` (build directory, optimization, debug info, stack-provenance `-ghc-options`, `--enable-coverage` only on the coverage flavors) and a `--dry-run` that prints the Cabal invocation without running it. Verify `bash -n scripts/with-flavor` and `--dry-run` for `dev`, `release`, `coverage-dev`, and `coverage-release` show the flags from the design table and do not pass `--ignore-project`.
- [x] 1.2 After a successful `dev` or `release` command, collect only `*.hie` into `dist/<flavor>/hie/{lib,exe,test}`, preserving module paths, and fail if any of those three directories is empty after `build all`. Skip collection for both coverage flavors. Verify with a fixture tree (fake component paths, no GHC build) that library, executable, and test files land in separate directories, a second run drops a removed file, and a coverage flavor does not write `hie/`.
- [x] 1.3 Remove the three `-hiedir=.hie/...` lines from `mndz-overlay-manager.cabal` and keep `-fwrite-ide-info`. Gitignore `dist/`. Verify `rg -n hiedir mndz-overlay-manager.cabal` finds no `-hiedir`, and `git check-ignore -q dist/dev dist/release dist/coverage-dev dist/coverage-release` succeeds.

## 2. Coverage entrypoint

- [x] 2.1 Point `scripts/coverage` at `with-flavor`, default flavor `coverage-dev`, overridable with `COVERAGE_FLAVOR`, and search that flavor's build directory for `.tix` and mix data instead of `dist-newstyle`. Verify `bash -n scripts/coverage` and `COVERAGE_FLAVOR=coverage-release scripts/coverage` is not required to run; a dry inspection (`rg`) shows both flavors are selected only through the helper and `dist-newstyle` is no longer the artifact root.

## 3. Quality hook

- [x] 3.1 Change `hk.pkl` so the non-coverage build is `scripts/with-flavor release -- build all`, the coverage step is still `./scripts/coverage`, stan reads `dist/release/hie/lib`, and weeder reads `dist/release/hie/{lib,exe,test}`. Verify `hk check -S stan -P --all` and `hk check -S weeder -P --all` name those directories, and `rg '\.hie/' hk.pkl` finds no old HIE paths.

## 4. Justfile and docs

- [x] 4.1 Add the root `justfile` from `design.md`: `default` lists recipes; `run` / `build` / `test` are dev; `run-release` / `build-release` / `test-release` are release; `coverage` and `coverage-release` match the spec; `check`, `format` (`hk fix -S tools-preflight -S ormolu`), `hlint`, `stan`, and `weeder` (the last two depend on `build-release`); `init` runs `init-tools` then `init-hooks`. `run` forwards arguments and drops one leading `--`. Verify `just --list` includes those recipes and omits `outdated`, `update`, `gencache`, `eclean`, `list`, and `github-token`, and `just --dry-run run -- --jobs 4 outdated crush` shows those four manager arguments and no leading `--`.
- [x] 4.2 Update `README.md`, `CONTRIBUTING.md`, and `AGENTS.md` in this same change: operator examples use `just run`; contributor docs name `just test`, `just check`, `just coverage`, `just coverage-release`, the four flavors, `just` 1.55 or newer, and `cabal.project.local` as the job cap that just recipes honor; AGENTS names `just check` as the gate and states that a coverage failure is the `coverage-dev` binary, rerun with `just coverage <pattern>`, and dumped with `+RTS -xc`. Verify the documented `just run` and `just coverage` lines match `just --list` and `just --dry-run`.

## 5. Integration

- [x] 5.1 Run `openspec validate --change justfile-build-flavors --strict` and `hk check`. Verify both exit 0. `hk check` is the proof that release HIE collection, debug coverage reports, hlint, stan, and weeder agree.
