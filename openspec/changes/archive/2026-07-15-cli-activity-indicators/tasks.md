## 1. Dependencies and CLI flags

- [x] 1.1 Add `layoutz` to library (and executable if needed) `build-depends` in `mndz-overlay-manager.cabal`
- [x] 1.2 Extend `Options` / `CLI.Parser` with `--jobs N`, `--no-progress`, and `--no-color`
- [x] 1.3 Fix verbosity parser so `-v` / `--verbose` works when `--log-level` is omitted; implement rule: explicit `--log-level` wins, else default warn with `-v` steps to info/debug
- [x] 1.4 Document new flags and jobs default in help text (cli-help scenarios)
- [x] 1.5 Resolve color mode from `--no-color` and non-empty `NO_COLOR`; resolve jobs default via `getNumProcessors` when flag omitted

## 2. Logging bootstrap

- [x] 2.1 Replace fixed `bootstrapLogger` with builder that applies `filterBySeverity` from verbosity
- [x] 2.2 Implement custom severity tags: Info green, Warning yellow, Error red, Debug magenta; plain tags when color disabled
- [x] 2.3 Wire `main` to parse options then install the configured logger (rebind after parse)
- [x] 2.4 Add optional log-message queue / deferred flush API for use while activity panels are active
- [x] 2.5 Tests: severity filter for default/warn/info/debug; NO_COLOR and `--no-color` strip escapes; `-v` / `-vv` / `--log-level` combinations

## 3. Concurrency pool

- [x] 3.1 Implement bounded package job runner (e.g. `QSem` + `mapConcurrently` or equivalent) parameterized by jobs count
- [x] 3.2 Switch `checkOverlay` (or caller) from sequential `mapM` to bounded concurrent checks
- [x] 3.3 Switch `applyOverlay` phase 1 from unbounded `mapConcurrently` to the same bounded pool
- [x] 3.4 Keep preflight and commit phases sequential
- [x] 3.5 Tests: with fake slow jobs, `--jobs 1` never exceeds one concurrent execution; concurrent outdated still produces correct reports

## 4. Activity UI core (layoutz)

- [x] 4.1 Add `CLI.Progress` / `Ui.Activity` module with enablement gate (TTY stderr and not `--no-progress`)
- [x] 4.2 Implement no-op backend used when indicators disabled (tests default here)
- [x] 4.3 Implement sequential step-bar helper (done/total + description, clear on complete) via layoutz
- [x] 4.4 Implement multi-progress host: top bar, spinner rows, success remove, fail retain, clear on complete
- [x] 4.5 Integrate log queue: hold co-log output during panel; flush after clear
- [x] 4.6 Honor color mode for indicator chrome (no ANSI when color disabled)

## 5. Wire outdated

- [x] 5.1 Run outdated checks under multi-progress when enabled; phase label for checking packages
- [x] 5.2 Defer `emitReport` stdout/warnings until after panel clear when indicators were shown
- [x] 5.3 Preserve machine stdout format and soft-warning semantics when indicators disabled
- [x] 5.4 Tests: non-TTY / `--no-progress` outdated output unchanged in structure; optional unit tests for report ordering after clear

## 6. Wire update

- [x] 6.1 Sequential preflight step bar for tool checks and conditional assets/token/ssh-agent setup steps
- [x] 6.2 Phase-1 multi-progress with package keys; status callbacks for Go sub-phase labels (fetch/vendor/assets/manifest as applicable)
- [x] 6.3 Sequential commit progress bar over successful packages
- [x] 6.4 Defer `emitOutcome` until after relevant panels clear; fail/soft-skip rows remain until clear
- [x] 6.5 Best-effort capture of child process stdout/stderr used by apply/git/vendor so indicators are not corrupted
- [x] 6.6 Tests: update with no-progress still emits success lines and warnings; hard-fail exit status unchanged

## 7. Quality gates

- [x] 7.1 Update weeder roots if new modules need them
- [x] 7.2 `hk fix` / ormolu and zero hlint
- [x] 7.3 `cabal build all && cabal test all`
- [x] 7.4 Full `hk check` green
