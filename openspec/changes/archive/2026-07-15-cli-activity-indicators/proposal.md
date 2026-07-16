## Why

`outdated` and especially `update` perform long network and process work with no interactive feedback, so users must inspect processes or network activity to know the program is alive. Concurrent multi-package work (and upcoming heavier techniques) makes silent runs worse. Separately, global verbosity flags are parsed but not applied to the logger, and log-level colors do not match the intended palette or respect `NO_COLOR`.

## What Changes

- Add interactive activity indicators for `outdated` and `update` using the `layoutz` library: multi-progress (top-level bar + per-package spinners) for concurrent package work; sequential step bars for preflight and commits.
- Suppress indicators when stderr is not a TTY, when `--no-progress` is set, or when running non-interactively as specified.
- Queue persistent log messages and machine stdout success/outdated lines until indicators clear; show compact fail state on the panel for failed packages while the indicator is active.
- Parallelize `outdated` package checks (today sequential) under a shared job pool.
- Add top-level `--jobs N` (default: host CPU count / `nproc`-equivalent) to bound package-level concurrency for `outdated` and `update` phase 1.
- Add top-level `--no-progress` and `--no-color`; honor `NO_COLOR` for disabling ANSI in logs and indicators.
- Fix verbosity: wire `--log-level` / `-v` into co-log severity filtering; fix the parser so `-v` is not dead behind `--log-level`'s default value.
- Switch severity colors to: Info green, Warning yellow, Error red, Debug magenta (co-log custom formatter, not layoutz for log lines).

## Capabilities

### New Capabilities

- `cli-activity`: Interactive progress/spinner UI for long-running command work, TTY/flag gating, log queuing during indicators, and shared presentation rules (clear on complete, success vs fail panel behavior).
- `cli-concurrency`: Bounded package-level job pool (`--jobs`) shared by concurrent check/apply paths.
- `logging-bootstrap`: Severity filtering from CLI verbosity; custom severity palette; `NO_COLOR` / `--no-color` respect (main specs lacked a carried-forward logging capability; introduce here).

### Modified Capabilities

- `outdated-command`: Concurrent checks with multi-progress indicators; deferred report emission after indicators clear; no change to machine stdout line format.
- `update-command`: Preflight step bar, phase-1 multi-progress (including Go sub-phase labels), commit step bar; deferred outcome emission; soft/hard failure presentation on indicators.
- `cli-help`: Document new global flags (`--jobs`, `--no-progress`, `--no-color`).

## Impact

- **Dependencies**: add `layoutz`; keep `co-log` / `ansi-terminal` for log formatting; use existing `async` plus a semaphore/pool for bounded concurrency.
- **CLI**: `CLI.Parser` gains flags; verbosity combinator rewrite.
- **Logging**: `Logging.Bootstrap` gains filtered/colored/no-color logger construction and optional message queue for indicator sessions.
- **Update path**: `Update.Check` concurrent checks; `Update.Apply` / `Main` report progress callbacks and job limits; child process stderr best-effort capture so indicators are not corrupted.
- **Tests**: non-TTY / no-progress paths must remain deterministic; golden/assert machine stdout unchanged; verbosity and NO_COLOR coverage.
- **Non-goals**: spine (config/discovery) progress; multi-progress for sequential commits; replacing co-log with layoutz for log lines; timestamps/rich `fmtRichMessageDefault` (follow-up).
