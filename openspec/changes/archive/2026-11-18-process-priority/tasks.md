# Tasks

## 1. Priority model and settings

- [x] 1.1 Add the internal priority module with the request types, the shared validator, `merge` and `resolve` (floor flags, I/O ranking, "none" derived from the inherited nice). Verify with unit tests for absolute targets, both floors, a level implying best-effort, idle with a level rejected, out-of-range values rejected, and command-line I/O options replacing config I/O as a unit.
- [x] 1.2 Add the `--nice`, `--ionice-class` and `--ionice-level` global options using the shared validator, and document them in top-level help (absolute values, floor, containers follow, I/O scheduler dependence). Verify with parser tests for valid, out-of-range, negative, realtime and idle-with-level input, and a help test for the three options and the scheduler note.
- [x] 1.3 Add the `nice`, `ionice-class` and `ionice-level` config keys to `OverlayConfig` using the shared validator. Verify with config tests for valid keys, an out-of-range error naming the key, and idle with a level rejected.

## 2. Host process application

- [x] 2.1 Add `cbits/ioprio.c` (`mndz_ioprio_get`, `mndz_ioprio_set`, and a `getpriority` wrapper that returns errno) to the cabal file, plus production thread ops. Verify `just build-release` succeeds and a smoke unit test reads the current thread's nice and I/O priority.
- [x] 2.2 Implement the sweep that repeats until no thread changes, over injected ops. Verify with fake-ops tests: one pass with no change, a thread added mid-pass needing another pass, a vanished TID skipped, the floor leaving higher values alone, and any other set failure returned as an error.
- [x] 2.3 Add the shared apply helper (resolve, warn once per floor, sweep, emit the `priority` event, return `EffectivePriority`) and call it after the config load in `runGitHubToken`, `runEclean` and `loadValidatedEbuildsFull`. A failure exits non-zero before any workload. Verify with tests for the warning text and once-per-run behavior, the `priority` event fields with and without a floor, and a child-process test running the executable with `--nice 19 --ionice-class idle` that checks every thread under `/proc/<pid>/task` and a spawned child.

## 3. Container workloads

- [x] 3.1 Add the pure prelude renderer and `priorityWrap` next to `Portage.MakeOpts`: unchanged argv at the default priority; nice and I/O handling with the floor and one stderr line; `exec` with no extra process. Verify with unit tests of the rendered argv, plus prelude script tests under `sh` with stub `nice` and `ionice` that cover a raise, a floor with its stderr line, and I/O class/level parsing (including the fallback to "none").
- [x] 3.2 Pass `EffectivePriority` into the smoke, materialize and Portage tools container configs, and apply `priorityWrap` in `smokeExecArgs` (both users), `materializeExecArgs` and `toolsExecArgs`, outside the GNU time wrapper. Verify with exec-argv tests showing the prelude comes before GNU time, setup execs left unchanged, and existing metrics tests showing `.inner` still names the real command.
- [x] 3.3 Add the session-setup tool check (`nice`/`ionice`, only when needed) to materialize and tools setup and to the smoke setup script, failing through the existing setup-failure cleanup. Verify with tests: a missing `ionice` fails setup naming the tool and starts no workload, and a run at default priority performs no check.
- [x] 3.4 Update README global options, config keys, the `--nice 0` "leave alone" note, containers following the manager's priority (including inherited `nice`/`ionice`), the I/O scheduler caveat, and the `nice`/`ionice` requirement for operator images. Verify every documented option and key matches the parser and config decoder.

## 4. Integration gates

- [x] 4.1 Check that the `process-priority`, `cli-help` and `run-metrics` deltas have no contradictions, confirm that image recipes and generator identities are unchanged, and pass `openspec validate process-priority --strict` and `just check` (which runs `hk check`).

## Workflow follow-up

- When archiving, merge the three deltas into the main specs, scrub any wording that only makes sense while the change is open, and validate the merged specs.
