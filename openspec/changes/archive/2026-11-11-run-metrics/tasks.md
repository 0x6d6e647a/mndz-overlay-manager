# Tasks

Phases follow design D1–D13. Each phase ends green under `just check` before the next starts.

## 1. Build identity (design D10)

- [x] 1.1 Wire `Paths_mndz_overlay_manager` as an `autogen-modules` + `other-modules` entry for the library. Verify `just build-release` succeeds and weeder no longer has a dangling `Paths_` root.
- [x] 1.2 Add `-DMNDZ_FLAVOR_<NAME>` to every flavor's GHC options in `scripts/with-flavor` (`DEV`, `RELEASE`, `COVERAGE_DEV`, `COVERAGE_RELEASE`). Verify `scripts/with-flavor --dry-run <flavor> -- build all` shows the define for each flavor.
- [x] 1.3 Add the leaf module `Build.GitRev`, a hand-written TH splice. It produces the revision from `git rev-parse HEAD` and the dirty flag from `git status --porcelain --untracked-files=no`. It calls `addDependentFile` on `.git/HEAD`, the resolved ref, and `.git/index`. With no git or `.git` it produces `unknown`/`False`. Verify with a test that the revision is 40 hex characters or `unknown`.
- [x] 1.4 Add `Build.Info` (CPP confined here). It exposes version, git revision, dirty flag, flavor (`unknown` without a define), and GHC version. Also add a startup `exeSha256` that hashes `/proc/self/exe` with `crypton`. Verify with tests for flavor mapping and the hash matching `sha256sum` of a fixture file. Verify hlint and ormolu pass on both modules.
- [x] 1.5 Update `CONTRIBUTING.md` with build identity: the flavor define, `unknown` outside `with-flavor`, TH revision staleness, and the `exe_sha256` cross-check (`project-docs` delta). Verify the text matches 1.2–1.4.

## 2. Run id, CLI flag, and startup checks (design D11)

- [x] 2.1 Add the global `--no-metrics` switch to `CLI.Parser` and the top-level help text. Verify a help test asserts `--no-metrics` appears in `--help` output (`cli-help` delta).
- [x] 2.2 Create the run id once in `runProgram` for work commands, using `formatRunId`. Change `openRunRoot` to take it (`openRunRootWith`), and pass it to `Spine`/`Main` callers and `resolveMaterializeDockerCfg`. Verify existing temp-workspace tests pass, and a new test that the run root name starts with the given run id.
- [x] 2.3 Implement the metrics startup gate behind an injectable ops record. It checks that `/usr/bin/time --version` contains `GNU Time`, and creates `<state>/mndz/overlay-manager/metrics/<run-id>-<command>/` using the `XDG_STATE_HOME` → `$HOME/.local/state` fallback. On failure it logs an error naming the path or tool and `--no-metrics`, and exits 1. It runs before config load. Verify with tests for a missing time, non-GNU time, an unwritable directory, and a `--no-metrics` bypass with a fake ops record that asserts it was not called.
- [x] 2.4 Add warnings: "metrics disabled by --no-metrics" on `outdated`/`update`/`gencache`/`eclean`, and "metrics are not collected for <cmd>; --no-metrics has no effect" on `list`/`github-token`. Verify with tests that capture logger output for each case.

## 3. Recorder core (design D1, D2, D4, D12, D13)

- [x] 3.1 Add the `Metrics` record and its no-op instance. Add a field for it to `ProgressConfig`, and update `mkProgressConfig` and the test helpers. Verify the existing test suite passes unchanged with the no-op instance.
- [x] 3.2 Implement the JSONL writer: encoding on the calling thread, a `Chan`, a single writer thread, monotonic `t_ns`, and degrade-on-first-`IOException` with one warning. Verify with tests: lines are valid JSON in order. With an injected failing handle: one warning, later events dropped, and the command result is unaffected.
- [x] 3.3 Implement spans: per-run increasing ids, a per-`ThreadId` stack shared across the run, `withSpan` with the outcome taken from the result or exception, and parent capture in `CLI.Jobs.mapConcurrentlyN`. Find every other fork point with `grep -rn "async\|forkIO\|forConcurrently\|mapConcurrently" src` and add capture where spans can be opened. Verify with tests that nested spans get the right parent, that a span in a `mapConcurrentlyN` child has the caller's span as parent, and that a killed run leaves a `span_start` with no `span_end`.
- [x] 3.4 Write the run header (`run_start`, `schema: 1`): build identity from group 1, host facts, the invocation (command, targets, excludes, jobs, refresh), time path and version, and capability count. Verify with a golden test of header keys using fake inputs.
- [x] 3.5 Write the footer (`run_end`): exit status, outcome (`completed`/`early-exit`/`interrupted`), last phase, wall time, `getrusage` SELF/CHILDREN, `GHC.Stats` when enabled, counters, and `metrics_degraded`. Add `-T` to the executable `-with-rtsopts`. Verify with tests: an unknown package target produces `early-exit` and status 1, and a `UserInterrupt` produces `interrupted`. Verify `ghc` stats are present when running the built binary.
- [x] 3.6 Implement the secret set and argv redaction: the token after `prepareGitHubToken`, and `secretMaterializeEnvKeys` values. Verify with a test that an argv containing the token records `<redacted>`, and that no event has an `env` key.
- [x] 3.7 Wire the recorder into `runProgram`: open it after the startup gate, add the command root span and phase spans in `runUpdatePhases`, and write the footer on every exit path. Verify by running `just run outdated` against the dev overlay and checking that `run.jsonl` starts with `run_start`, ends with `run_end`, and passes `jq -c .`.

## 4. Process measurement (design D5, D6, D7)

- [x] 4.1 Add `prMeasure :: Measure` (`Timed | TimedContainerExec | Lifecycle | Untimed`, default `Timed`) to `ProcessRequest`. Update the constructors and test fakes. Verify the build is clean and existing tests pass.
- [x] 4.2 Implement the `timedRunner` decorator: executable resolution with an unwrapped fallback when the tool is missing, the `/usr/bin/time -o <file> --quiet -f <fmt> -- …` rewrite for `ExecCmd` and `ShellCmd`, a `proc` span (redacted argv, cwd, exit, stdout/stderr bytes), time-file ingest then delete, and kept file plus `time_parse_error` on failure. Verify with unit tests on a fake inner runner: the rewritten argv, unchanged stdout/stderr/exit, a missing tool behaving the same as unwrapped, deletion after a parsed file, and keeping a malformed file.
- [x] 4.3 Add a real-binary test that runs `sh -c 'echo x >&2; exit 2'` through `timedRunner productionCommandRunner`. Verify stderr `x`, exit 2, and a `time` object with numeric `wall_s` and string `cpu_pct`.
- [x] 4.4 Apply `timedRunner` everywhere production hands out `productionCommandRunner` (Main, Spine, the ops constructors). Verify with a grep that no production path passes a bare `productionCommandRunner` when metrics are on.
- [x] 4.5 Add wall-clock `proc` spans (no `time` object) around the direct calls in `Update.Git`, `GitHub.readGitRemoteUrl`, `Distfiles.lookupPortageDistDir`, `Cargo.V8Deps`, `GpgAgent` (`runGpg`, `gpgconf --kill`), and `SshAgent` (`kill`, `ssh-add` with `interactive: true`). Mark `git commit -S` and `git push` `interactive: true`. Verify with a test via the git ops in a temp repo that a `proc` span for `git` is recorded.
- [x] 4.6 Docker inner wrap and mount: `materializeExecArgs` prefixes `innerCmd` with the inner time wrap (`.inner` file), the outer decorator writes the `.outer` file, both sit under one parent span with a `container` attr, and `materializeCreateArgs` adds the time-dir `--mount` only when recording. Mark the session `docker create`/idle as `Lifecycle`. Verify with argv tests for both recording on and off (`temp-workspace` delta scenarios).
- [x] 4.7 Add a session GNU time check: `docker exec <name> /usr/bin/time --version` once per session when recording. The unit hard-fails with the image name and `--no-metrics` if it fails. Verify with tests using a fake runner for the failing and `--no-metrics` cases (`ensure-materialize-image` delta).
- [x] 4.8 Add a container cgroup snapshot before `docker rm -f`: inspect `State.Pid`, read `/proc/<pid>/cgroup`, read `cpu.stat` and `memory.peak`, and emit a `container` event, with the reason on failure. Register the cgroup for the sampler's "ours" test (group 6). Verify with tests on a fake proc and sysfs root for the success and missing-file cases.
- [x] 4.9 Add `sys-process/time` to the base `emerge -n` line in `Update.Materialize.Recipe`, and bump `materializeGeneratorId` to `mndz-overlay-manager-materialize-9`. Verify with recipe golden tests updated to show `sys-process/time`, and that a sidecar with generator `-8` is a miss.

## 5. Concurrency, HTTP, interactive, counters (design D3, D9)

- [x] 5.1 Derive spans from progress: wrap `MultiHandle` from `withMultiProgress` (start, step, status, success, skip, fail) and `StepHandle` from `withStepProgress`, with package attrs. Verify with a test that drives a fake multi handle through start, step, step, skip and asserts three spans and the outcome `skip`.
- [x] 5.2 Add `slot.wait` spans to `mapConcurrentlyN` (kind `jobs`), `withWorkSlot` (kind `work`), and `aePackSlot` acquisition (kind `pack`), each with capacity. Verify with a test where two actions contend for a capacity-1 slot and one `slot.wait` span covers the other's run.
- [x] 5.3 Implement HTTP spans at the manager (`instrumentManagerSettings`, design D9): method, host, path (GitHub route templating, query dropped), status, and body bytes, without reading request headers. Apply it to every production `Manager` (`newMetricsManager`). Verify with tests for templating `/repos/o/r/releases/latest` → `/repos/{owner}/{repo}/releases/latest` and with a request carrying a token in a header over a fake connection, checking no token appears in the encoded span.
- [x] 5.4 Add `prompt` spans with `interactive: true` in `pauseActivePanel`/`resumeActivePanel`. Verify with a test that pause then resume yields one `prompt` span.
- [x] 5.5 Add counters: check-cache hits and misses (where `cacheSummaryLine` is computed), GitHub calls and last rate-limit remaining, image `built|reused|not-needed`, package selected/needs-work/applied/skipped/failed, and packed asset bytes. Verify with tests on the footer counters for a fake outdated run with a warm and a cold cache.

## 6. Machine telemetry (design D8)

- [x] 6.1 Implement `/proc` parsers behind a `ProcRoot` path: stat CPU deltas, loadavg, meminfo, pressure (optional), diskstats (whole disks), per-PID stat. Verify with fixture-directory tests, including a missing `/proc/pressure`.
- [x] 6.2 Implement process selection: "ours" by ppid ancestry from our PID plus registered container cgroups, every process of ours plus the top 10 others by CPU delta, `comm` only. Verify with fixture tests: our tree is complete, 10 foreign processes are present with `ours: false`, and no cmdline key appears.
- [x] 6.3 Implement the sampler thread: a sample at start, then every 5 seconds, a final sample before the footer, cancelled on run end. Verify with a test using an injected clock or tick that a short run has a start and an end sample.

## 7. Operator docs and integration

- [x] 7.1 Update `README.md` with run metrics: default on for the four work commands, the location pattern and `run.jsonl`, retention, the GNU `/usr/bin/time` requirement, `--no-metrics` and its warning, and the one-time image rebuild (`project-docs` delta). Add `--no-metrics` wherever README lists global options. Verify against `--help` output.
- [x] 7.2 Manual end-to-end check: `just run-release update <a DepsAndAssets package>` with Docker. Confirm `.inner`/`.outer` pairs, a `container` event, samples with PSI, the footer counters, and an empty `time/` directory on success. Confirm Ctrl-C during a wrapped command still interrupts, and the footer shows `interrupted`.
- [x] 7.3 Run `openspec validate run-metrics --type change --strict` and verify it exits 0.
- [x] 7.4 Run `just check` and verify the full gate exits 0.

## Workflow follow-up

- The handoff for moving direct process calls onto `CommandRunner` is already written at `/home/mndz/repos/hostel/mndz_wiki/computing/projects/mndz-overlay-manager/handoffs/run-metrics-process-runner-migration-handoff.typ`. After apply, refresh its inventory if task 4.5 changed which call sites exist.
- Archive the change after review. Archiving syncs the delta specs into `openspec/specs/`. Do not edit the living specs during apply.
- After a few weeks of data, start an explore session to analyze runs and decide whether a `metrics` command is warranted.
