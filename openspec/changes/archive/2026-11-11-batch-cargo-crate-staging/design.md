# Design

## Context

See `proposal.md` (Why). Requirements are in `specs/cargo-crates-assets/spec.md`.

Today `Update.Cargo.Crates.stageAndArchive` walks the registry packages from `Cargo.lock` in order. For each one, `stageOne`:

1. checks `distdir/<crate>.crate` on the host;
2. calls `extractCrate`, which sends `ExecCmd "tar" ["-xzf", crate, "-C", gentoo]` through the unit's `CommandRunner`;
3. checks that the crate directory appeared and writes `.cargo-checksum.json` on the host.

It stops at the first failure. Progress fires `cgpOnStageCrate k n` before each crate.

Under `withFullPathMaterializeSession`, the runner is the session runner, and `materializeExecArgs` turns every request into `docker exec --user U [--workdir] [--env …] [-i] <container> cmd args…`. The unit `work/` directory is bind-mounted at the same path inside the container, so host and container see the same paths. `-i` is added only when `prStdin` is non-empty.

Unit layout (`buildCargoCratesTarball`): the unit directory contains `work/`, whose children are `src/`, `distdir/`, and `stage/` (holding `cargo_home/gentoo/`). `pycargoebuild.log` is written in the unit directory as `takeDirectory workDir`.

### Measurements

Measured on 2026-11-11 on an 8-core host against `mndz-overlay-manager/materialize:local`. The input was 890 `.crate` files from `/var/cache/distfiles` (138 MB, 936 MB unpacked). All five extract mechanisms produced trees identical to a host extract.

| Mechanism | Wall time |
|---|---|
| `docker exec … true` (bare exec overhead) | 42 ms per exec |
| Host `tar`, serial, no docker (floor) | 3.39 s |
| One exec per crate, serial (current) | 40.93 s |
| One exec per crate, `-P 2 / 4 / 8 / 16 / 32` | 24.6 / 16.9 / 15.8 / 15.0 / 15.0 s |
| One exec, serial loop in container | 3.19 s |
| 8 batch execs, concurrent | 1.41 s |
| **One exec, `xargs -P 8` in container (chosen)** | **0.94 s** |
| Crates pack: `tar -cJf`, `-T8 -9e --block-size=64MiB` | 113.2 s (56 MB output) |

Live smoke, same day: `update dev-util/mise` (2026.11.6 → 2026.11.7) showed `staging 1151 crates` once. The status was replaced by `crates pack` too quickly to time by eye.

A re-stage of the same 890 distfiles crates, with one `docker exec` of `xargs -0 -P 8` in `mndz-overlay-manager/materialize:local`, took 1.465 s wall time. It left 890 crate directories and no `.err` files. That number is the extract only.

Further spikes:
- Exec latency under concurrent 8-thread xz load: 36 ms, so no degradation.
- 6000 arguments of 200 bytes each through one `docker exec`: accepted.
- A loop over `tar` stopping on a corrupt `.crate`: printed tar's stderr plus the failing path, exited 1, and left later crates untouched.

## Goals / Non-Goals

**Goals:**
- Remove the per-crate `docker exec` cost by running all extraction in one builder invocation.
- Keep failure reporting deterministic (lock order) despite concurrent extraction.
- Keep the change local to cargo crate staging, reusing `CommandRunner`, `ProcessRequest.prStdin`, and the existing progress host.

**Non-Goals:**
- No streaming progress from inside the invocation (`CommandRunner` only returns output after exit).
- No shared cross-unit budget for extraction processes.
- No change to `createArchiveAtomic`, `packTarXzAtomic`, or `xzOptValue`.

## Decisions

### D1. One `xargs -0 -P W` invocation fed on stdin

The extraction request is:

```
ExecCmd "xargs"
  ["-0", "-P", show W, "-n", "1",
   "sh", "-c", EXTRACT, "sh", <gentooDir>, <errDir>]
prStdin = NUL-joined absolute crate paths, in lock order
```

`EXTRACT` is a fixed script. It reads `$1` (destination), `$2` (error directory), and `$3` (crate path, which `xargs` appends):

```
f=$3; e=$2/${f##*/}.err
tar -xzf "$f" -C "$1" 2>"$e" || exit 1
rm -f "$e"
```

- **Paths stay out of the script.** Every path is a positional argument or a stdin item, so no shell quoting is involved.
- **Stdin has no size limit.** Paths on stdin avoid ARG_MAX entirely, which removes any need to chunk the list.
- **Failures don't stop the run.** A failing crate exits `1`, so `xargs` keeps going and finishes with status `123`. The wrapper never exits `255`, which would make `xargs` stop early.
- **Each failure keeps its own stderr.** Each crate's stderr goes to its own file under `work/crate-errors/`. Concurrent `tar` processes never interleave output in a shared pipe, and no stdout parsing or framing is needed.
- **`work/` is visible to both sides.** It is bind-mounted, so the host reads the `.err` files directly after the invocation.
- **The error directory is outside the archive.** `work/crate-errors/` is a sibling of `stage/`, so it can never be archived.

Alternatives considered:
- **One exec per crate under `mapConcurrentlyN`.** Plateaus at about 15 s because dockerd exec throughput caps it, and every concurrent unit shares that cap.
- **Batches of execs, each running a serial loop.** 1.41 s, but it needs a chunking policy and adds a barrier at each chunk boundary.
- **One exec running a serial loop.** 3.19 s. Simplest, but it ignores `--jobs`.
- **In-process decompression.** Needs new `tar`/`zlib` dependencies, bypasses the runner the tests stub, and the remaining 1-3 s isn't worth it.
- **Paths on argv.** Works at current sizes (6000 args tested), but it puts a limit back in place that stdin avoids for free.

### D2. Width W is the resolved `--jobs` value

`mkCargoOps` already receives `aeJobs` as `threads` (also used for xz `-T`). Staging reuses it as W, so no new configuration is needed.

The worst-case process fan-out is `jobs × jobs` `tar` processes, when every admitted unit stages at once. Each lasts about 1 s and runs before the compress slot. A shared `WorkBudget` was rejected: holding W budget slots across one opaque exec needs new acquisition code for a burst this short.

### D3. Host-side phases in lock order

```
stageAndArchive
  1. preflight: doesFileExist for every package (lock order)
       any missing -> failure records (kind missing), skip 2-3
  2. onStage n (n >= 1); run the D1 invocation
  3. for each package in lock order:
       errDir/<crate>.err exists          -> record (extract, file contents)
       else crate dir missing             -> record (no directory)
       else write .cargo-checksum.json
     no records but invocation exit /= 0  -> invocation failure (D5)
  4. records non-empty -> write log, return summary error
  5. onArchiveStart; createArchiveAtomic (unchanged)
```

Checksum files are only written for crates that staged cleanly. When any record exists, pack fails before archiving, so a partial tree is never packed.

### D4. Failure summary and `crate-staging.log`

The log path is `takeDirectory workDir </> "crate-staging.log"`, which is the unit directory, matching `pycargoebuild.log`. `stageAndArchive` receives only `stageDir`, so the unit directory is derived as `takeDirectory (takeDirectory stageDir)`, or passed in explicitly (implementer's choice; the explicit form is clearer).

Log format, one block per record in lock order:

```
<crate filename>: <missing | extract | no directory>
    <full extract stderr, indented four spaces>   (extract only)
```

Summary message shapes (singular when the count is 1):

```
cargo crates pack failed: 3 registry crates missing from distdir <distdir>; first: a-1.0.0.crate; see <unit>/crate-staging.log
cargo crates pack failed: 2 crates failed to stage; first: a-1.0.0.crate: gzip: stdin: not in gzip format; see <unit>/crate-staging.log
```

When the log write throws an `IOException`, the message replaces `see …` with a note that the log could not be written. This mirrors the pycargoebuild transcript behaviour.

### D5. Invocation-level failure

The invocation can fail with no `.err` files and every crate directory present, for example when `xargs` is absent (exit 127), or when the container died or docker failed (exit 125 or 126). Pack then hard-fails with `cargo crates pack failed: crate extraction invocation exited <code>: <stripped stderr>`. No log is written, because no per-crate record exists. Exit `123` with no records cannot happen with this wrapper. If it does, it is treated the same way.

### D6. Progress hook

`CargoProgress.cgpOnStageCrate :: Int -> Int -> IO ()` becomes a hook taking only the crate count. `packCratesTarballWith`'s `onStage` parameter changes to match. `cargoCratesProgress` renders `staging N crates`, or `staging 1 crate`. With zero registry crates the hook is not called and no invocation runs; `createArchiveAtomic` still runs as today.

## Risks / Trade-offs

- [Up to `jobs²` concurrent `tar` processes across units] → Short-lived (about 1 s per unit), it runs before the compress slot, and it was measured to have no effect on exec latency under xz load.
- [`xargs` or `sh` missing in the builder environment] → Both are in `@system` in the Gentoo stage3 image and the run used them. D5 surfaces their absence as a clear invocation failure.
- [Thousands of `.err` files on a corrupted distdir] → Created only for failing crates, inside the retained unit, and removed with the unit on success.
- [Losing per-crate progress] → Accepted. Staging takes about 1 s at `--jobs 8` and about 3 s at `--jobs 1`.
- [Test runners that delegate `tar` to the production runner] → They need to delegate the `xargs` request too, or stub it by writing crate dirs and `.err` files. The host has GNU `xargs`.
- [Running every crate after an early failure wastes work] → At most about 1 s, in exchange for a complete failure report.

## Migration Plan

No data or config migration. Rollback is a revert of the change. Archives produced before and after are byte-compatible, because extraction order doesn't affect output.

## Open Questions

None.
