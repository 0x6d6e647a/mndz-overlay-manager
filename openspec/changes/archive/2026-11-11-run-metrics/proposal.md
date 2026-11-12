# Proposal

## Why

There is no record of where `outdated`, `update`, `gencache`, and `eclean` spend their time. Most wall time goes to subprocesses (Docker materialize, `git`, `xz`, `egencache`), network calls, and waits for parallel slots, and none of it is measured. There is also no way to tell whether a slow run came from a code change, a cold cache, or another process loading the machine. Runs need to be recorded with the build that produced them, so that a few weeks of data can be analyzed for patterns and regressions.

## What Changes

- **Run recording on by default** for the work commands `outdated`, `update`, `gencache`, and `eclean`. Each run writes one directory, `${XDG_STATE_HOME:-$HOME/.local/state}/mndz/overlay-manager/metrics/<run-id>-<command>/`, holding a `run.jsonl` event file. Runs are kept indefinitely.
- **New global flag `--no-metrics`** turns recording off for one run, and the program logs a warning that metrics are disabled. On `list` and `github-token`, which never record, the flag is accepted with a warning that it has no effect. There is no config key.
- **GNU time is required on the host.** Unless `--no-metrics` is set, a work command checks for GNU time at `/usr/bin/time`, and that the metrics directory can be written, before loading config. If either check fails, the program exits with status 1 and the message names `--no-metrics`.
- **Each run file records:**
  - **Run header:** build identity (package version, git revision and dirty flag, build flavor, GHC version, SHA-256 of the running executable), host facts, the invocation (command, targets, `--jobs`, `--refresh`), and the run id. The run id is shared with the temp workspace and the materialize container labels.
  - **Nested spans,** written as separate start and end events. They cover:
    - command phases and per-package steps
    - explicit sub-steps
    - waits for job, work-budget, and pack slots
    - HTTP requests
    - time spent waiting on interactive prompts
    - subprocesses
    - the lifetime of long-lived processes
  - **Subprocess resource use** captured by `/usr/bin/time`, one file per process, read into the run file and then deleted (kept when they cannot be parsed). Commands run in the materialize container are measured twice, outside around `docker exec` and inside the container. Command arguments are recorded with known secrets redacted. The environment is never recorded.
  - **Machine telemetry** every 5 seconds from `/proc`, including pressure stall information (PSI). Each sample lists all of the manager's own processes plus the 10 busiest other processes.
  - **Container snapshot:** a cgroup CPU and peak-memory reading for each materialize container before it is removed.
  - **Run footer:** exit outcome (including early exits), resource usage of the process and its children, GHC runtime statistics, and counters that make runs comparable (check-cache hits and misses, GitHub calls, image built or reused, package counts, bytes packed).
- **Recording never changes a run's outcome.** A write failure during the run disables recording for the rest of that run and logs one warning.
- **Materialize image changes:**
  - The generated image installs `sys-process/time`, and the generator identity changes so existing images are rebuilt.
  - Unless metrics are off, a materialize container whose image lacks GNU time hard-fails that unit. This includes `MNDZ_MATERIALIZE_IMAGE` override images.
  - The unit's metrics `time/` directory is bind-mounted into the container.

## Capabilities

### New Capabilities

- `run-metrics`: Per-run performance recording for work commands. Covers the `--no-metrics` opt-out, the GNU time requirement, the run directory and event format, build identity, spans, subprocess resource capture, machine telemetry, container snapshots, the footer, and the rule that recording never fails a run.

### Modified Capabilities

- `temp-workspace`: The full-path container bind-mount rule allows the unit's metrics `time/` directory in addition to `work/` and `out/`.
- `ensure-materialize-image`: The generated image provides GNU `/usr/bin/time`. When metrics are on, a materialize image without GNU time (generated or override) hard-fails the unit.
- `cli-help`: Top-level help documents the global `--no-metrics` option.
- `project-docs`: `README.md` documents run metrics at operator depth (location, opt-out, the GNU time requirement, retention).

## Non-goals

- A `metrics` subcommand, comparison tooling, or dashboards. The first goal is to collect data. A later change can design analysis once real data shows what is needed.
- GHC eventlog tracing, and per-span Haskell allocation or GC attribution.
- A telemetry sampler inside the materialize container. Host-side sampling plus the cgroup snapshot covers this change.
- Moving calls that bypass `CommandRunner` (`Update.Git`, `GpgAgent`, `SshAgent`, `GitHub.readGitRemoteUrl`, `Distfiles`, `Cargo.V8Deps`) onto the shared runner. In this change they get wall-clock spans only. The follow-up is captured in the wiki handoff `run-metrics-process-runner-migration-handoff.typ`.
- A config key for metrics, pruning or retention limits, and per-layer timing of `docker build`.
- Any change to package selection, PV selection, or the work commands' results.

## Impact

- **Code:**
  - New metrics modules: recorder and writer, span handle, time decorator, `/proc` sampler, build info.
  - `app/Main.hs`: run id created at startup, startup check, header and footer.
  - `CLI.Parser`: the `--no-metrics` flag.
  - Instrumentation in `CLI.Progress`, `CLI.Jobs`, `Update.Process` and `Update.Process.Docker`, `Update.Http` and the GitHub fetchers, `Update.Spine`, `Update.Apply`, and `Update.TempWorkspace` (run id passed in).
  - `Update.Materialize.Recipe`/`Sidecar`: the `sys-process/time` package and the generator bump.
- **Build:**
  - The `TemplateHaskell` extension in one leaf module, for the git revision.
  - A CPP flavor define passed from `scripts/with-flavor`.
  - The `Paths_mndz_overlay_manager` autogen module.
  - `-T` added to the executable's RTS options.
  - No new Hackage dependencies are expected (uses `template-haskell`, `process`, and existing hashing).
- **Runtime:**
  - GNU `/usr/bin/time` becomes a host requirement for work commands unless `--no-metrics` is set.
  - A one-time materialize image rebuild.
  - A new state directory under XDG state.
- **Docs:** README, plus CONTRIBUTING for the flavor define and build identity.
