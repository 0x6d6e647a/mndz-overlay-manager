# Design

## Context

See proposal.md for motivation and specs/ for the required behavior.

- On Linux, nice and I/O priority belong to each thread, not the whole process. `setpriority(PRIO_PROCESS, tid, …)` and `ioprio_set(IOPRIO_WHO_PROCESS, tid, …)` change one thread, and a new thread inherits from the thread that creates it. The executable uses `-threaded -N`, so several OS threads exist before `main` runs. A spawned child inherits from whichever OS thread happens to fork it.
- `runProgram` parses arguments, starts metrics (writing `run_start` and spawning `/usr/bin/time --version`), then dispatches. Each command loads its config itself: `runGitHubToken` (plaintext-token variant), `runEclean`, and `loadValidatedEbuildsFull` for the remaining work commands. The GPG and SSH supervisors and all workload processes are spawned after those loads.
- Container processes descend from the Docker daemon, not from the manager, so they don't inherit its priority. Workload commands go through three `docker exec` builders: `smokeExecArgs`, `materializeExecArgs` and `toolsExecArgs`. With metrics on, the first two wrap the command in GNU time (`.inner`). Setup execs (`configurePortageSession`, the GNU time version check, the smoke disk report) are built separately.
- `PORTAGE_NICENESS`, `nice -n` and `ionice` are increments or self-applied settings. Combining them with a wrapper would count the priority twice.
- Existing FFI precedent: `cbits/rusage.c` (`mndz_` prefix) and `ccall` imports for `prctl`, `ioctl`, `flock` and `statvfs`.

## Goals / Non-Goals

**Goals:**

- One pure resolution step from command-line options, config and inherited values to the effective priority, with floor flags. Unit-testable without changing real priority.
- Applying the priority to the host process with no race, and testable through injected operations.
- One shared container prelude used by all three workload exec builders, so the rules can't drift apart.

**Non-Goals:**

- Re-executing the manager, or running code before RTS initialisation (a C constructor).
- Changing setup or lifecycle execs, image recipes, or container create flags.
- Lowering the priority of a running container's processes from the host.

## Decisions

### Resolve once, as a pure function

Add an internal priority module with:

- `PriorityRequest`: an optional nice, plus an optional I/O setting that is either `Idle` or `BestEffort (Maybe level)`.
- `merge cli config`: the command-line nice replaces the config nice, and any command-line I/O option replaces the whole config I/O setting.
- `resolve request inherited`: returns the effective nice and I/O priority plus a floor flag for each.

The I/O ranking treats an inherited "none" class as best-effort at `(nice + 20) / 5`, computed from the *inherited* nice. The request validation rules (ranges, idle with a level, a level alone meaning best-effort) live in one validator that both the option parser and the TOML decoder use.

*Alternative:* separate validation in the parser and the decoder. Rejected because the two would drift apart.

### Apply to the host by sweeping threads until nothing changes

`applyToAllThreads ops target`:

1. List `/proc/self/task`.
2. For each TID, read its nice and I/O priority and set any value that is below the target. A TID that disappeared (`ESRCH`, or a missing `/proc` entry) is skipped.
3. Repeat until a pass changes no thread.

The pass that changes nothing proves convergence. Every thread that existed when that pass started was already at the target, so any thread created during or after it inherits the target from an already-updated parent.

`ops` is a record (`listTasks`, `getNice`, `setNice`, `getIoprio`, `setIoprio`). Unit tests use fakes, including one that adds a thread mid-pass and one where a thread exits. Production `ops` use `ccall` into a new `cbits/ioprio.c`: `mndz_getpriority`/`mndz_setpriority` (thin wrappers returning errno), `mndz_ioprio_get`/`mndz_ioprio_set`, and `mndz_gettid` for the calling thread. These wrap `syscall(SYS_ioprio_*)`, so the variadic `syscall` is never called through the FFI. The shim also returns `getpriority`'s value and errno together, avoiding the ambiguity of -1 being both an error and a real nice value. Any other failure is fatal for the run.

*Alternative:* set priority on the calling thread, then exec self. Rejected for these reasons:

- It needs `getFullArgs` to keep `+RTS` flags.
- `executeFile` can't keep argv[0], so `getProgName` and optparse's usage text would change.
- Anything done before the exec is lost, which becomes a startup ordering rule every future change must respect.
- It's hard to test.
- A failed exec still needs a fallback.

### Apply in one shared helper at config load

Wrap the three config-load sites in `withCommandPriority` (or a function each calls right after a successful load). It:

1. reads the inherited values from the calling thread,
2. resolves them against `merge cli (config keys)`,
3. logs the floor warnings,
4. sweeps all threads,
5. emits the `priority` metrics event,
6. returns `EffectivePriority`.

Each command passes `EffectivePriority` into `resolveMaterializeDockerCfg`, `resolveToolsContainerCfg` and the smoke container config, the same way `rtJobs` is passed. This uses the config each command already loads under its own permission rules, and it runs before any supervisor or workload is spawned. The only earlier child is `time --version`, and it doesn't matter. Each command loads its config once, so the helper runs once per run and the warning and event appear once.

*Alternative:* read the config early in `runProgram`. Rejected: that would duplicate loading and the `config-file-permissions` handling, and the sweep doesn't need to run first.

### Container prelude: a shell wrapper outside GNU time

Add `priorityWrap :: EffectivePriority -> [String] -> [String]`. It returns the argv unchanged when the effective values are nice 0 with no explicit I/O class. Otherwise it returns:

```
sh -c '<prelude>' mndz-priority <inner argv...>
```

The prelude:

1. Reads the current nice (`nice`) and I/O priority (`ionice -p $$`).
2. For I/O: if the target ranks at or below the current value, runs `ionice -c <class> [-n <level>] -p $$`. Otherwise prints one floor line to stderr.
3. For nice: if the current value is below the target, runs `exec nice -n $((target - current)) "$@"`. Otherwise prints one floor line (when the target is higher priority than the current value) and runs `exec "$@"`.

The prelude sets I/O priority on its own shell process and then `exec`s, so the command inherits it and no second process remains. It's rendered by a pure function in `Process.Priority` (beside the request and resolution types, since it serves smoke, materialize and tools containers alike, not only Portage), and its values come from typed integers and class constructors, so no operator text is interpolated. The container nice target is `max 0` of the effective nice, and an inherited realtime class is not propagated (containers cannot be granted either). At a nice target of 0 the prelude leaves nice alone.

**Order:** prelude → GNU time → command. This differs from the "time outermost" placement discussed during exploration. With the prelude outside, GNU time still wraps the real command directly, so `.inner` measures and names `go`/`emerge`, not `sh`. The prelude `exec`s away before time starts, so it adds nothing to the measurement.

The prelude is applied in all three workload exec builders, including smoke `AsRoot` execs, because the smoke emerges run as root. The smoke setup script runs through a separate session exec (`ssSetup`) without the prelude, so its tool check reports a missing tool instead of the prelude failing first.

*Alternative:* `PORTAGE_NICENESS` or `PORTAGE_IONICE_COMMAND` in make.conf. Rejected: Portage-only, applied as increments, and it would count twice with any wrapper.

### Tool check during session setup

When `priorityWrap` would change the argv, session setup first runs `command -v nice` (when the nice target is above 0) and `command -v ionice` (when an I/O class is set), through the existing setup exec path. It fails with `container setup failed: <tool> not found (needed for process priority)`, using the same cleanup path as MAKEOPTS configuration failures. Smoke adds the same check to its setup script.

## Risks / Trade-offs

- [I/O priority has no effect under the `none` or `kyber` schedulers, the usual NVMe default] → Help text and the README state the scheduler dependence. Applying is still correct when it has no effect.
- [`ionice -p` output format differs between util-linux versions] → The prelude parses only the class word and the `prio N` field, falling back to "none" when it can't parse. Tests run against the stage3 output format.
- [Busybox-based operator images: `nice` exists, but busybox `ionice` may be missing] → The setup check fails clearly, and only when I/O priority is requested.
- [Tests can't lower the test process's priority again] → The real sweep test runs in a child process: the test binary re-executes itself in a probe mode (like the GPG TTY probe) that parses `--nice 19 --ionice-class idle` with the real option parser, applies it with the production ops through the shared helper, and spawns a child. The test inspects `/proc/<pid>/task/*/stat` field 19 and `ioprio_get` for every thread and the child. Everything else uses fake ops.
- [A thread sits in `clone` while a pass lists tasks] → Covered by the convergence argument: the child appears in a later pass, so a pass that changes nothing is final.

## Migration Plan

Default behaviour is unchanged for an operator whose shell runs at nice 0 with no I/O class and who sets no options. An operator whose shell is already niced will see container workloads follow that priority. Image recipes and generator identities are unchanged. To roll back, revert the change; nothing is persisted.
