# Design

## Context

See `proposal.md` for motivation and `specs/run-metrics/spec.md` for the observable contract. The codebase already has the seams this design builds on:

- **`ProgressConfig`** (`CLI.Progress`) is passed into every place that opens a progress display: `withMultiProgress` and `withStepProgress` in `Main`, `Update.Apply`, `Update.Apply.Plan`, `Update.Check`, and `Update.Spine`. `MultiHandle` reports per-package start, step, status, success, skip, and fail. `pauseActivePanel`/`resumeActivePanel` bracket interactive prompts.
- **`CLI.Jobs`** owns concurrency: `mapConcurrentlyN` (package slots), `WorkBudget` (2 × jobs nested work), and `withSlot`. The pack slot is `aePackSlot :: QSem` in `Update.Apply.Env`.
- **`Update.Process.CommandRunner`** (`ProcessRequest -> IO ProcessResult`) is injected into most domain `*Ops` records. `Update.Process.Docker.materializeExecArgs` builds `docker exec … name cmd args` from a host request, and `materializeCreateArgs` builds the session's `docker create`.
- **`HttpLbs`** (`Update.Http`) is the injected HTTP function shared by the GitHub, Go, npm, and release code.
- **`Update.TempWorkspace.openRunRoot`** generates the run id and is called only from the `update` path (`Spine`, `Main`).
- **`Update.Materialize.Sidecar.materializeGeneratorId`** (`…-materialize-8`) invalidates images when the recipe generator changes.
- Calls that bypass `CommandRunner`: `Update.Git`, `GitHub.readGitRemoteUrl`, `Distfiles.lookupPortageDistDir`, `Cargo.V8Deps`, and parts of `GpgAgent`/`SshAgent`.
- **Build:**
  - The executable uses `-threaded -rtsopts -with-rtsopts=-N`.
  - No module uses TH or CPP yet.
  - `weeder.toml` already roots `Paths_mndz_overlay_manager.*`, but the cabal file does not list that module.
  - `scripts/with-flavor` owns the per-flavor GHC flags and output directories.

## Goals / Non-Goals

**Goals:**

- One recorder value per run, carried through existing seams instead of new parameters on every function.
- Instrumentation is mostly decorators: around `CommandRunner`, `HttpLbs`, the progress handles, and slot acquisition. Domain code changes stay small.
- Existing tests keep their fake runners and progress handles unchanged. When recording is off, the program behaves as it does today.
- Decisions made in exploration are recorded here, with the alternatives that were rejected.

**Non-Goals:**

- Accurate CPU attribution for each span inside the Haskell process. RTS and rusage totals cover the whole process and stay in the footer.
- A stable public library API for metrics. The modules are internal (`other-modules`).
- Per-layer timing of `docker build`. The whole ensure build is one span.

## Decisions

### D1. The recorder travels in `ProgressConfig`

Add a `Metrics` record, holding the operations below, as a field of `ProgressConfig`. When metrics are off, the record's operations do nothing.

```
Metrics
  enabled        :: Bool
  spanStart      :: SpanName -> Attrs -> IO SpanId     -- parent from thread context
  spanEnd        :: SpanId -> Outcome -> Attrs -> IO ()
  withSpan       :: SpanName -> Attrs -> IO a -> IO a  -- bracket; outcome from Either/exception
  bump / gauge   :: CounterKey -> ... -> IO ()
  event          :: Value -> IO ()                     -- sample / container lines
  timeDir        :: Maybe FilePath
```

- *Why:* every orchestration path already receives `ProgressConfig`, so reaching it is a field read, not a signature change across dozens of functions.
- *Alternative:* a new parameter in `Runtime`, `ApplyEnv`, and each environment record. This keeps concerns cleaner but touches many signatures.
- *Alternative:* a global `IORef` created with `unsafePerformIO`. Rejected: tests could not isolate it.

### D2. Implicit parents through a per-thread span stack, propagated at fork points

Each thread keeps a stack of open spans in a map keyed by `ThreadId`, shared across the run. `withSpan` pushes and pops. `spanStart` uses the top of the calling thread's stack as the parent. `mapConcurrentlyN`, and any other place that forks work (`async`, `forConcurrently`), captures the caller's current span and puts it at the bottom of each child thread's stack.

- *Why:* package jobs run on their own threads, so "the current package span" is naturally per thread. Passing parents explicitly would change every `*Ops` function.
- *Alternative:* explicit `SpanCtx` arguments. These are always correct, but very invasive.
- *Alternative:* no nesting. This loses the tree structure the analysis needs.
- *Risk:* a fork point that doesn't propagate makes its spans show up as roots. A test checks that spans in a package job have a parent, and grepping for `async`/`forkIO` gives the full list of fork points to review.

### D3. Spans derived from progress, plus explicit `withSpan`

`withMultiProgress` and `withStepProgress` wrap the handles they produce:

- `mhStart` opens a package span.
- `mhStep`, `mhStatus`, and `mhWait` close the previous step span and open the next one. Step spans are named `step` and carry the step text in an `attrs.step` attribute, so span names stay a small dotted vocabulary.
- `mhSuccess`, `mhSkip`, and `mhFail` close the open step and the package span with the matching outcome.
- `withStepProgress` opens a span for the whole step bar, and `shStep` gives one child span per step.

Explicit `withSpan` adds command and phase roots (in `Main` and `runUpdatePhases`) and deeper sub-steps where they are useful.

- *Why:* every step the operator sees gets a span immediately, with no domain code changes.
- *Alternative:* explicit spans only. More precise, but coverage would depend on remembering to add them.

### D4. Single writer thread over a `Chan`

Every event is encoded to a strict `ByteString` line on the calling thread and pushed to a `Chan`. One writer thread appends each line and flushes. On run end, a sentinel drains the channel, the footer is written, and the handle is closed. On the first `IOException`, the writer sets a "degraded" flag: later pushes do nothing, the logger emits one warning, and the footer, if it can still be written, records `metrics_degraded`.

- *Alternative:* an `MVar` lock around `hPutStr`. Simpler, but a slow disk would stall package threads.
- *Alternative:* `stm` `TQueue`. Adds a dependency for no gain here.
- Timestamps come from `GHC.Clock.getMonotonicTimeNSec`, minus the run start. The header carries one wall-clock anchor.

### D5. Process measurement is a `CommandRunner` decorator

`timedRunner :: Metrics -> CommandRunner -> CommandRunner` handles each request in four steps:

1. **Resolve the executable.** `ExecCmd` with a non-absolute command uses `findExecutable`. If the command is not found, the request goes to the inner runner unwrapped, so missing-tool behavior is exactly as it is today. This is the spec's "Missing tool keeps its failure" scenario.
2. **Rewrite the command.**
   - `ExecCmd cmd args` becomes `ExecCmd "/usr/bin/time" ["-o", f, "--quiet", "-f", fmt, "--", cmd] <> args`.
   - `ShellCmd s` becomes the same prefix followed by `["sh", "-c", s]`.
3. **Run it inside a `proc` span**, recording the redacted argv, cwd, exit code, and stdout/stderr byte counts.
4. **Read the time file, then delete it.** If parsing fails, keep the file and record `time_parse_error`.

The format string writes a JSON object directly:

```
{"wall_s":%e,"user_s":%U,"sys_s":%S,"cpu_pct":"%P","max_rss_kb":%M,
 "major_faults":%F,"minor_faults":%R,"swaps":%W,"invol_ctx":%c,
 "vol_ctx":%w,"fs_in":%I,"fs_out":%O,"exit":%x}
```

- `%C` is left out because it contains unescaped quotes and may contain secrets.
- `%t %K %D %X %p %k` are left out because they are always zero on Linux.
- `%P` is kept as a string. It prints `?` when elapsed time is zero, so it cannot be a JSON number.

Production wiring applies the decorator where `productionCommandRunner` is handed out. Tests use their fake runners directly and test the decorator on its own, with a fake inner runner and a fake time file.

**Requests that must not be wrapped.** `ProcessRequest` gains `prMeasure :: Measure` (`Timed | TimedContainerExec | Lifecycle | Untimed`), with `Timed` as what every constructor sets unless it says otherwise. The decorator honors it:

- The session's `docker create` (whose command is the idle `sleep infinity`) is `Lifecycle`.
- `docker rm`/`inspect` stay `Timed`.
- The session runner marks the host `docker exec` of a measured command `TimedContainerExec`: the decorator wraps it like `Timed` but names the time file `.outer` (D6), without matching on the command name.

*Alternative:* match on the command name. Rejected as fragile.

**Lifecycle spans.** Long-lived processes get one `lifecycle` span from start to stop, opened *detached* (`mSpanStartDetached`): it records the current span as its parent but does not become the parent of later work on that thread. The GPG and SSH session supervisors open one at spawn and close it at reap. The materialize container's lifetime is the `container.session` span around the unit's work. The supervisors' own cleanup (`gpgconf --kill`, `kill` of the agent) runs in the supervisor process, outside the recorder, so it is not timed.

### D6. Docker: inner and outer wrapping

- **Inner wrap.** `materializeExecArgs` builds `innerCmd` with the inner wrap: `/usr/bin/time -o <time-dir>/<id>-<slug>.inner.json --quiet -f fmt -- cmd args`.
- **Outer wrap.** `timedRunner` wraps the resulting `docker exec` request with a `.outer` file.
- **Shared parent.** Both share the parent span opened by the session runner for each exec, with attrs `container` and the logical command.
- **Bind mount.** `materializeCreateArgs` adds a third `--mount` for the time directory when recording. That directory is bind-mounted at the same path, and the container runs as the host uid:gid, so files land owned by the operator.
- **Session check.** At session start, run `docker exec <name> /usr/bin/time --version` once. The unit hard-fails if GNU Time is missing (`ensure-materialize-image` delta).

### D7. Container cgroup snapshot through the container's init PID

Before `docker rm -f`:

1. Run `docker inspect -f '{{.State.Pid}}' <id>` to get the container's init PID.
2. Read `/proc/<pid>/cgroup` to get the cgroup v2 path.
3. Read `/sys/fs/cgroup/<path>/cpu.stat` (`usage_usec`, `user_usec`, `system_usec`) and `memory.peak`.

- *Why:* the cgroup path depends on the Docker cgroup driver (`system.slice/docker-<id>.scope` versus `docker/<id>`). OpenRC hosts usually use cgroupfs. Going through `/proc/<pid>/cgroup` works with either driver.
- If any step fails, the `container` event records the reason.

### D8. Telemetry sampler thread

A sampler thread starts after the header and is stopped with `cancel` before the footer, which writes the final sample.

- **Per-sample sources:**
  - CPU mode deltas: `/proc/stat`
  - Load and process counts: `/proc/loadavg`
  - Memory: `/proc/meminfo`
  - PSI: `/proc/pressure/*`, skipped if absent
  - Disk: `/proc/diskstats`, summed bytes over whole-disk devices
- **Process scan:** reads `/proc/[pid]/stat` for every PID and keeps the previous tick's CPU ticks per PID to compute CPU%.
- **Which processes are "ours":**
  - descendants of our PID, found by walking ppid in the scan
  - PIDs whose `/proc/<pid>/cgroup` matches a container cgroup registered at session start (D7 resolves it then as well)
- Every process of ours is emitted, plus the top 10 others by CPU%. Only `comm` is recorded; the cmdline never is.
- `/proc` sits behind a `ProcRoot` file path, so tests point it at fixture directories.

### D9. HTTP spans at the manager

Every production HTTP `Manager` is built from `instrumentManagerSettings :: Metrics -> ManagerSettings -> ManagerSettings` (`Update.Http.newMetricsManager`). Each request is one `http` span with method, host, path, status, and response body bytes:

- `managerWrapException` (once per request, around redirects) opens the span from the request line and ends it `fail` on an exception.
- `managerModifyResponse` wraps the body reader: it counts bytes and ends the span when the body reaches its end, with the status.
- For `api.github.com` and `uploads.github.com`, a small route templater maps known shapes to placeholders: `/repos/{owner}/{repo}/releases/latest`, `/repos/{owner}/{repo}/tags`, release asset uploads, and so on.
- Query strings are dropped.
- Request headers are never read, so tokens never reach a span.
- The same hook bumps `github.api_calls` for `api.github.com` and sets `github.rate_limit_remaining` from the response's `x-ratelimit-remaining`.
- *Why not an `HttpLbs` decorator:* `Update.Deps.Plan` and several fetchers take a raw `Manager` and call `httpLbs` directly, so a decorator on `HttpLbs` would miss those requests unless `Metrics` were threaded through every such function. The manager hook covers every request with `Metrics` needed only where managers are created.

### D10. Build identity

- **Package version:** from `Paths_mndz_overlay_manager.version`. Add `autogen-modules` and `other-modules` entries. The existing weeder root then becomes meaningful.
- **Flavor:**
  - `scripts/with-flavor` adds `--ghc-options=-DMNDZ_FLAVOR_<NAME>` for its flavor.
  - One small module, `Build.Info`, with `{-# LANGUAGE CPP #-}`, maps the define to `dev | release | coverage-dev | coverage-release`, and to `unknown` when no define is set (plain `cabal build`).
  - Each flavor already has its own `dist/<flavor>`, so the define never causes rebuilds within a tree.
- **Git revision and dirty flag:**
  - A hand-written TH splice in a leaf module, `Build.GitRev`, imported only by `Build.Info`.
  - It runs `git rev-parse HEAD` and `git status --porcelain --untracked-files=no`, and calls `addDependentFile` on `.git/HEAD`, the resolved ref file, and `.git/index`.
  - It produces `"unknown"` when git or `.git` is missing, so builds from a source tarball still work.
  - *Alternative:* the `githash` package. Rejected to avoid a dependency for about 20 lines of code.
  - *Alternative:* a CPP define for the revision. Rejected: a new `-D` on every commit changes `ghc-options` and rebuilds everything.
- **Executable hash:** SHA-256 of `/proc/self/exe` at startup, using `crypton` (already a dependency). This is the ground truth when the TH label is stale.
- **Lint interplay:**
  - HIE records the code the splice produced, so weeder and stan see ordinary code.
  - hlint and ormolu parse the `TemplateHaskell` and `CPP` pragmas.
  - Keep CPP confined to `Build.Info`, since ormolu has limited CPP support.

### D11. Startup order in `runProgram`

1. Parse options and set up the logger.
2. If the command records metrics:
   - With `--no-metrics`: log a warning.
   - Without `--no-metrics`: check GNU time (`/usr/bin/time --version` contains `GNU Time`), create the run directory, open the recorder, write the header, and start the sampler.
3. If the command does not record and `--no-metrics` was given: log a "no effect" warning.
4. Load config and dispatch.
5. When the command finishes, write the footer from the exit code or exception.

The run id is created in step 2 for every work command, including runs with `--no-metrics`, so the temp workspace still gets one. `openRunRoot` becomes `openRunRootWith runId`, and the `Spine`/`Main` callers pass the run id from `Runtime`.

The footer's outcome:

- `ExitSuccess` from a finished dispatch → `completed`
- an `ExitFailure` raised before the work phase → `early-exit`
- `UserInterrupt` → `interrupted`
- otherwise → `completed` with the non-zero status

The last phase entered is the most recent phase span opened under the command root.

### D12. GHC runtime statistics in the footer only

- Add `-T` to the executable's `-with-rtsopts`.
- At footer time, if `getRTSStatsEnabled`, record: `allocated_bytes`, `max_live_bytes`, `max_mem_in_use_bytes`, `gcs`, `major_gcs`, `mutator_cpu_ns`, `gc_cpu_ns`, `cpu_ns`, `elapsed_ns`, `copied_bytes`, `par_copied_bytes`, `cumulative_par_balanced_copied_bytes`.
- Also record `getrusage` for `RUSAGE_SELF` and `RUSAGE_CHILDREN` (user, sys, max RSS). The `unix` package has no `getrusage` binding, so a small C shim (`cbits/rusage.c`, a library `c-sources` entry) fills those fields; the same file provides the page size the sampler uses for RSS.
- Not per span: these counters cover the whole process.

### D13. Secret redaction

The recorder holds a set of secret strings: the resolved GitHub token after `prepareGitHubToken`, and the values of `secretMaterializeEnvKeys` when present. Argv elements are passed through a replace-all before encoding. Environment values are never passed to the recorder.

### Rejected and deferred alternatives

- **GHC eventlog** (`traceMarkerIO` + `+RTS -l`): gives excellent per-capability and GC detail, but its binary format has no build header, and it is aimed at GHC-level tuning rather than optimizing the overall procedure. Deferred.
- **Telemetry sampler inside the container:** the host already sees container load through `/proc` and PSI, and the cgroup snapshot covers processes the time wrapper never sees. Deferred as future work.
- **Per-span `GHC.Stats` or per-phase snapshots:** these can't be attributed under concurrency. Deferred.
- **`--append` to a single time file:** concurrent writes can interleave, and the link to each span is lost.
- **Moving direct process calls onto `CommandRunner`:** deferred. See the wiki handoff `run-metrics-process-runner-migration-handoff.typ`.

## Risks / Trade-offs

- **Fork/exec overhead of one extra process per command.** It's around a millisecond. Cargo crate staging is already batched, so process counts are moderate. → Compare `proc` counts against total wall time in the first data.
- **Thread-context gaps (D2) produce orphan spans.** → Test that spans opened in package jobs have a non-null parent, and review every fork point.
- **Time file left behind if the program is killed or interrupted mid-process.** On Ctrl-C the `proc` span ends `fail` without reading the file, because GNU time may still be writing it. → It's harmless. Files stay under the run directory and match the "kept on failure" rule.
- **TH revision staleness when cabal reports "Up to date".** → `exe_sha256` reveals it, and CONTRIBUTING explains it.
- **`%M` is the largest single process, not the whole tree.** This applies under `sh -c`, `make -j`, and similar. → Documented in the spec field meaning. The container `memory.peak` gives the tree total for container work.
- **Sampler cost on hosts with thousands of processes.** → A `/proc` scan every 5 seconds is cheap. If the first data shows overhead, gate the process scan.
- **Interactive commands under time** (`git commit -S`, `git push`). These are not routed through the shared runner in this change (handoff), so the TTY behavior is unchanged.
- **GNU time ignores SIGINT while it waits on the child.** The child still receives the terminal's SIGINT through the process group, and time exits with the child's status. → Ctrl-C behavior is unchanged. Covered by a manual check in tasks.
- **Async exceptions swallowed by best-effort recording.** A catch-all around sampling or time-file reads would eat Ctrl-C (`UserInterrupt`) or the sampler's `cancel`. → Best-effort paths use `trySync`, which rethrows asynchronous exceptions. `withRunMetrics` masks setup until the header is written, then runs the sampler and body inside the `try`, so an interrupt at any point after the header still gets a footer.
- **Image rebuild cost** from the generator bump. → One time only. The BuildKit cache ids are unchanged, so binpkgs are reused.

## Migration Plan

- First run after upgrading:
  - Hosts without GNU time fail with guidance. Install `sys-process/time`, or use `--no-metrics`.
  - The materialize image is rebuilt once.
- Rollback: revert the change. Run directories are inert data and can be deleted by hand.
