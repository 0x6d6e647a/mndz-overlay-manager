# Process Priority

## Why

Long `update` and `smoke` runs compete with interactive work for CPU and disk. Running the manager under `nice` today lowers only the manager and its local helpers. The heavy work (emerge, materialize builds, Portage tools) runs inside Docker containers that start from the daemon's priority, so that work stays at full priority. Operators need one setting that lowers the priority of the whole run.

## What Changes

- Add the global options `--nice N` (0–19), `--ionice-class idle|best-effort` and `--ionice-level N` (0–7, best-effort). Add matching config keys `nice`, `ionice-class` and `ionice-level`. Command-line values replace config values. For I/O priority, any ionice option on the command line replaces the whole config I/O setting.
- Values are absolute targets with a floor. The manager never raises its priority above what it inherited. When the inherited priority is already lower than the target, the manager keeps it and warns once.
- Apply the effective priority to every thread of the manager process before it spawns any workload process, so every child inherits it.
- Run every container workload command at the manager's effective nice and I/O priority. This includes priority the manager only inherited, for example from an outer `nice`, with no option given. Workloads that need a priority change fail session setup if the image lacks the tools to apply it.
- Record the requested and effective priority, and whether the floor applied, as a `priority` event in run metrics.
- Document the options, config keys, the `--nice 0` "leave alone" behavior and the dependence on the I/O scheduler in help text and the README.

## Capabilities

### New Capabilities

- `process-priority`: the operator priority settings, how they resolve and are applied to the manager process, and how they are propagated to container workloads.

### Modified Capabilities

- `cli-help`: top-level help documents the priority options.
- `run-metrics`: a new `priority` event kind records the requested and effective priority.

## Impact

- CLI parsing, config loading, and the shared startup path where commands load their config.
- A new internal priority module with a small C shim for the I/O priority syscalls (next to `cbits/rusage.c`).
- The `docker exec` argument builders for smoke, materialize, and Portage tools sessions, and their session setup.
- Operator-supplied images (`MNDZ_MATERIALIZE_IMAGE`) need `nice` and `ionice` when a priority change applies.
- Documentation: README global options, config keys, and runtime tool requirements.

## Non-goals

- Negative nice values, the realtime I/O class, or granting `CAP_SYS_NICE` to containers.
- Priority for Docker image builds (smoke and materialize Dockerfiles) or BuildKit.
- Setting `PORTAGE_NICENESS` or `PORTAGE_IONICE_COMMAND`.
- Relative (increment) semantics for any option.
- cgroup CPU or I/O weights for containers.
