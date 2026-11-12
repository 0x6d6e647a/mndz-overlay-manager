# Spec Delta

## Purpose

Records how long each part of a work-command run takes, along with process resource use, machine load, and the build that ran it, in a per-run file so performance can be compared across builds and runs.

## ADDED Requirements

### Requirement: Work commands record a run by default

When the operator runs `outdated`, `update`, `gencache`, or `eclean` without `--no-metrics`, the program SHALL record that run to a run metrics directory. `list` and `github-token` SHALL NOT record a run.

#### Scenario: Update records a run

- **WHEN** the operator runs `update` with no `--no-metrics`
- **THEN** a new run metrics directory exists after the command finishes
- **AND** it contains a `run.jsonl` file for that run

#### Scenario: List does not record

- **WHEN** the operator runs `list`
- **THEN** no run metrics directory is created for that invocation

### Requirement: --no-metrics disables recording with a warning

The global option `--no-metrics` SHALL disable run recording for that invocation. When a work command that would otherwise record runs with `--no-metrics`, the program SHALL log a warning at the start of the run stating that metrics are disabled by `--no-metrics`. There SHALL be no configuration key that enables or disables metrics.

#### Scenario: Opt-out warns and writes nothing

- **WHEN** the operator runs `outdated --no-metrics`
- **THEN** the program logs a warning that metrics are disabled by `--no-metrics`
- **AND** no run metrics directory is created
- **AND** the command's exit status and results are the same as they would be with metrics on

### Requirement: --no-metrics on a command that never records

When `--no-metrics` is given with `list` or `github-token`, the program SHALL accept it and SHALL log a warning that metrics are not collected for that command, so the option has no effect. The exit status SHALL NOT change.

#### Scenario: List with --no-metrics

- **WHEN** the operator runs `list --no-metrics`
- **THEN** the program logs a warning that metrics are not collected for `list`
- **AND** `list` output and exit status are unchanged

### Requirement: GNU time is required unless metrics are disabled

Before loading configuration, a work command that will record SHALL verify that `/usr/bin/time` exists, runs, and reports itself as GNU Time. If it does not, the program SHALL log an error naming `/usr/bin/time` and the `--no-metrics` option, and SHALL exit with status `1` before any package, network, or Docker work. With `--no-metrics` this check SHALL NOT run.

#### Scenario: Missing GNU time fails early

- **WHEN** `/usr/bin/time` is absent and the operator runs `update`
- **THEN** the program exits with status `1`
- **AND** the error names `/usr/bin/time` and `--no-metrics`
- **AND** no GitHub request, package check, or Docker command was made

#### Scenario: Non-GNU time fails early

- **WHEN** `/usr/bin/time --version` does not identify GNU Time and the operator runs `gencache`
- **THEN** the program exits with status `1` with the same guidance

#### Scenario: Opt-out bypasses the check

- **WHEN** `/usr/bin/time` is absent and the operator runs `update --no-metrics`
- **THEN** the GNU time check does not fail the command

### Requirement: Metrics directory must be writable

Before loading configuration, a work command that will record SHALL create its run metrics directory. If the directory cannot be created or written, the program SHALL log an error naming the path and `--no-metrics`, and SHALL exit with status `1` before any package work.

#### Scenario: Unwritable state directory

- **WHEN** the metrics parent directory is not writable and the operator runs `outdated`
- **THEN** the program exits with status `1`
- **AND** the error names the directory and `--no-metrics`

### Requirement: Run metrics directory location

The program SHALL create each run's directory at `<state>/mndz/overlay-manager/metrics/<run-id>-<command>/`, where `<state>` is `XDG_STATE_HOME` when set and non-empty, otherwise `$HOME/.local/state`, and `<command>` is the work command name. The run's event file SHALL be `run.jsonl` in that directory.

#### Scenario: Default state home

- **WHEN** `XDG_STATE_HOME` is unset, `HOME` is `/home/op`, and `update` records run id `20261111T101500-0700-4242.a8f3`
- **THEN** the event file is `/home/op/.local/state/mndz/overlay-manager/metrics/20261111T101500-0700-4242.a8f3-update/run.jsonl`

### Requirement: One run id per invocation

The run id SHALL use the format defined for temp-workspace run roots. A work command SHALL create one run id at startup and SHALL use it for the run metrics directory, for the product temporary workspace run root when one is opened, and for the run label on materialize containers.

#### Scenario: Temp root and metrics share the id

- **WHEN** `update` opens a temp workspace run root and records metrics
- **THEN** the temp run root directory name and the metrics directory name begin with the same run id
- **AND** the run header's `run_id` equals that id

### Requirement: Runs are retained

The program SHALL NOT delete or prune run metrics directories.

#### Scenario: Older runs remain

- **WHEN** the operator runs `outdated` twice
- **THEN** both run metrics directories exist afterwards

### Requirement: Event file is JSON Lines with a schema version

`run.jsonl` SHALL contain one JSON object per line. Every object SHALL have an `ev` field naming the event kind (`run_start`, `span_start`, `span_end`, `sample`, `container`, `run_end`). Every object except `run_start` SHALL have `t_ns`, the monotonic nanoseconds since the run started. The `run_start` line SHALL be first and SHALL carry `schema`, an integer format version.

#### Scenario: First line is the header

- **WHEN** a recorded run's `run.jsonl` is read
- **THEN** its first line has `"ev":"run_start"` and an integer `schema`
- **AND** every other line has an `ev` and a non-negative integer `t_ns`

#### Scenario: Unknown fields are additive

- **WHEN** a later build adds a new span name or a new attribute to an existing event
- **THEN** `schema` does not change

### Requirement: Run header records build identity

The `run_start` event SHALL include a `build` object with the package version, the git revision the binary was built from, whether tracked files differed from that revision at build time, the build flavor (`dev`, `release`, `coverage-dev`, `coverage-release`, or `unknown`), the GHC version, and the SHA-256 of the running executable file. When the revision is not known at build time, it SHALL be recorded as `unknown`.

#### Scenario: Release build header

- **WHEN** a binary built with the release flavor from a clean checkout records a run
- **THEN** `build.flavor` is `release`, `build.git_dirty` is `false`, and `build.git_rev` is that commit's full hash
- **AND** `build.exe_sha256` is the SHA-256 of the executable that ran

#### Scenario: Stale revision is detectable

- **WHEN** two runs report the same `build.git_rev` from executables with different contents
- **THEN** their `build.exe_sha256` values differ

### Requirement: Run header records host, invocation, and time tool

The `run_start` event SHALL include the run id, the command, the local start time in ISO 8601 extended form with offset, the host CPU count, kernel release, machine architecture and total memory, the resolved `--jobs`, `--refresh` when applicable, package targets and excludes as given, the `/usr/bin/time` version, and the number of runtime capabilities.

#### Scenario: Invocation is reproducible from the header

- **WHEN** the operator runs `update --jobs 4 --refresh dev-util/foo`
- **THEN** the header records command `update`, jobs `4`, refresh `true`, and targets `["dev-util/foo"]`

### Requirement: Spans are nested start and end events

The program SHALL record each measured step as a `span_start` event when it begins and a `span_end` event when it ends. `span_start` SHALL carry an `id` unique within the run (a positive integer, increasing in start order), the `parent` span id or `null`, a dotted `name`, and an `attrs` object. `span_end` SHALL carry the same `id`, an `outcome` (`ok`, `skip`, or `fail`), and may add `attrs`. Span names are not a closed set.

#### Scenario: Sub-step nests under its step

- **WHEN** a package step starts a sub-step during `update`
- **THEN** the sub-step's `span_start.parent` is the package step's `id`

#### Scenario: Crash leaves open spans visible

- **WHEN** the process is killed while a span is running
- **THEN** `run.jsonl` contains that span's `span_start` and no matching `span_end`

### Requirement: Spans cover phases and package steps

Each recorded run SHALL have a root span for the command. Command phases (for `update`: plan, preflight, classify, disk gate, mutate) SHALL be spans under it. Every package progress step the operator can see (per-package start, step changes, success, skip, failure) SHALL produce a span carrying the package `category/package` in its attrs.

#### Scenario: Package step timeline

- **WHEN** `update` advances `dev-util/foo` through steps it shows as progress
- **THEN** each of those steps appears as a span whose attrs name `dev-util/foo`
- **AND** a soft-skipped package's span ends with outcome `skip`

### Requirement: Waits for parallel slots are spans

Each wait for a package job slot, a nested work-budget slot, or the shared pack compression slot SHALL be recorded as a span named `slot.wait` with attrs naming the slot kind and its capacity, ending when the slot is acquired.

#### Scenario: Pack slot contention is visible

- **WHEN** two units are ready to pack at the same time during `update`
- **THEN** one unit has a `slot.wait` span with kind `pack` whose duration covers the other unit's compression

### Requirement: HTTP requests are spans

Each HTTP request the program makes SHALL be recorded as a span with attrs for method, host, path, response status, and response body size. For `api.github.com`, the path SHALL be a route template with owner, repository, tag, and asset identifiers replaced by placeholders. Query strings, request headers, and tokens SHALL NOT be recorded.

#### Scenario: GitHub API call

- **WHEN** `outdated` fetches the latest release for a GitHub-hosted package
- **THEN** a span records host `api.github.com`, a path template, and the status code
- **AND** the span contains no token or `Authorization` value

### Requirement: Interactive waits are marked

Time spent waiting on the operator (passphrase or token prompts, and signing or SSH steps that may prompt) SHALL be recorded in spans whose attrs include `interactive: true`. While the progress display is paused for a prompt, the program SHALL record a `prompt` span covering that pause.

#### Scenario: Passphrase prompt

- **WHEN** `update` pauses its progress display for a GPG passphrase prompt
- **THEN** a `prompt` span with `interactive: true` covers the time until the display resumes

### Requirement: Subprocesses are measured with GNU time

When recording, each subprocess run for command work through the product's shared command execution SHALL be started as `/usr/bin/time -o <file> --quiet -f <format> -- <command> <args…>` and SHALL be recorded as a `proc` span. Wrapping SHALL NOT change the command's stdout, stderr, stdin, or exit status as seen by the program.

#### Scenario: Wrapped command output is unchanged

- **WHEN** a wrapped command writes to stderr and exits with status `2`
- **THEN** the program sees the same stderr text and exit status `2` as an unwrapped run

#### Scenario: Missing tool keeps its failure

- **WHEN** a command run through the shared execution names an executable that does not exist
- **THEN** the program reports the same missing-tool failure it reports with `--no-metrics`

### Requirement: Process span contents

A `proc` span SHALL record the command basename, the argument list after redaction, the working directory when set, the exit status, stdout and stderr byte counts, and a `time` object read from the time file with keys `wall_s`, `user_s`, `sys_s`, `cpu_pct` (string, as reported), `max_rss_kb`, `major_faults`, `minor_faults`, `swaps`, `invol_ctx`, `vol_ctx`, `fs_in`, `fs_out`, `exit`.

#### Scenario: Time data is attached

- **WHEN** a wrapped `xz` process finishes
- **THEN** its `proc` span's `time.max_rss_kb` and `time.wall_s` are numbers
- **AND** `time.cpu_pct` is a string such as `"387%"`

### Requirement: Time files are per process and read into the run

Each wrapped process SHALL write its own time file under the run metrics directory's `time/` subdirectory, named `<span-id>-<slug>[.outer|.inner].json` where the slug identifies the package and command basename. After the process ends the program SHALL read the file into the `proc` span and delete it. When the file cannot be read or parsed, the program SHALL keep it and record `time_parse_error` on the span.

#### Scenario: Successful ingest removes the file

- **WHEN** a wrapped process ends and its time file parses
- **THEN** the file is gone from `time/` and its data is on the `proc` span

#### Scenario: Unparseable file is kept

- **WHEN** a time file is empty or malformed
- **THEN** the file remains in `time/`
- **AND** the `proc` span has a `time_parse_error` attribute

### Requirement: Container commands are measured inside and outside

For each command run in a materialize container, the program SHALL wrap the host `docker exec` invocation (`.outer` time file) and the command inside the container (`.inner` time file). Both SHALL be recorded under one parent span so outer and inner results can be compared, and the inner span SHALL name the container.

#### Scenario: Inner and outer pair

- **WHEN** full-path materialize runs `go mod vendor` in the container
- **THEN** the run has a `.outer` result for the `docker exec` and an `.inner` result for `go`, both under the same parent span

### Requirement: Long-lived processes are not wrapped

Processes that live for the session (the materialize container's idle process and the GPG and SSH session supervisors) SHALL NOT be wrapped with GNU time. Each SHALL have a lifecycle span from start to stop.

#### Scenario: Container session span

- **WHEN** a materialize container session starts and is later removed
- **THEN** one span covers the session's lifetime
- **AND** no time file is written for the container's idle process

### Requirement: Arguments are redacted and environment is never recorded

Before recording command arguments, the program SHALL replace every occurrence of a known secret value (the GitHub token in use and secret environment values the product passes to commands) with `<redacted>`. The program SHALL NOT record environment variable values of any process.

#### Scenario: Token in an argument

- **WHEN** a command argument contains the GitHub token in use
- **THEN** the recorded argument shows `<redacted>` in place of the token

### Requirement: Other subprocesses have wall-clock spans

Subprocesses the program starts outside the shared command execution (git operations, GPG and SSH agent commands, Portage `DISTDIR` lookup, and rusty_v8 snapshot reads) SHALL each be recorded as a `proc` span with wall-clock timing and exit status, without a `time` object.

#### Scenario: Git push is timed

- **WHEN** `update` pushes the overlay
- **THEN** a `proc` span for `git` with its duration and exit status exists in the run

### Requirement: Machine telemetry samples

While recording, the program SHALL write a `sample` event at run start, every 5 seconds, and at run end. Each sample SHALL include CPU utilisation by mode, load averages and running and total process counts, memory and swap use, CPU, memory, and IO pressure stall averages when the kernel provides them, and disk read and write bytes since the previous sample.

#### Scenario: Pressure is recorded

- **WHEN** the kernel exposes `/proc/pressure/io`
- **THEN** each sample includes IO pressure `some` and `full` averages

#### Scenario: Short run still has samples

- **WHEN** a recorded run lasts under 5 seconds
- **THEN** `run.jsonl` contains a start sample and an end sample

### Requirement: Samples list our processes and the busiest others

Each sample SHALL list every running process that belongs to this run (descendants of the manager process or processes in its materialize containers) and the 10 other processes with the highest CPU use since the previous sample. Each entry SHALL give pid, parent pid, short command name, CPU percent, resident memory, state, and `ours`. Full command lines SHALL NOT be recorded.

#### Scenario: Foreign load is attributable

- **WHEN** an unrelated process uses most of the CPU during a recorded `update`
- **THEN** samples list it with `ours: false` and its short command name

### Requirement: Container resource snapshot

Before removing a materialize container, the program SHALL read the container's control-group CPU totals and peak memory and SHALL record them in a `container` event naming the container. When the values cannot be read, the event SHALL record the reason instead.

#### Scenario: Snapshot at teardown

- **WHEN** a full-path unit's container is removed after materialize
- **THEN** a `container` event for that container records CPU microseconds and peak memory bytes

### Requirement: Run footer

When the command finishes, including early exits and handled interrupts, the program SHALL write a `run_end` event with the exit status, an `outcome` (`completed`, `early-exit`, or `interrupted`), the last phase entered, total wall time, CPU time and peak resident memory for the process and its waited-for children, runtime memory and garbage-collection totals when available, and the run's counters.

#### Scenario: Early exit is recorded

- **WHEN** `update` exits with status `1` because a package target is unknown
- **THEN** `run_end` records outcome `early-exit`, exit status `1`, and the phase it stopped in

### Requirement: Comparison counters

The `run_end` counters SHALL include check-cache hits and misses, GitHub API calls and the last observed rate-limit remaining, whether the materialize image was built, reused, or not needed, package counts (selected, needing work, applied, skipped, failed), and total bytes of packed assets.

#### Scenario: Cold and warm runs differ in counters

- **WHEN** `outdated --refresh` runs and then `outdated` runs within the check-cache TTL
- **THEN** the first run's counters show cache misses and the second run's show cache hits

### Requirement: Recording never changes a run's outcome

After the startup checks pass, a failure to write metrics, read a time file, sample telemetry, or snapshot a container SHALL NOT change the command's exit status or results. On the first write failure the program SHALL log one warning and stop recording for the rest of the run.

#### Scenario: Disk full during a run

- **WHEN** writing `run.jsonl` fails partway through `update`
- **THEN** the program logs one warning that metrics recording stopped
- **AND** `update` continues and exits with the status it would have had without metrics
