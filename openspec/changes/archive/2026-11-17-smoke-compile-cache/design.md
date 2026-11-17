# Design

## Context

See `proposal.md` for motivation and `specs/smoke-compile-cache/spec.md` for the required behaviour.

Current state that shapes the approach:

- **Containers.** `smoke` creates one container per run (`Smoke.Container.smokeCreateArgs`) with `SYS_ADMIN`, the tree snapshot image, the overlay bind, and the volumes `mndz-smoke-binpkgs` and `mndz-smoke-distfiles`. A root setup script (`setupScript`) writes `/etc/portage` files and appends to `make.conf`. The dependencies step and the package step then run as `emerge` through `docker exec`.
- **Sequential runs.** Runs within one command never overlap (`cli-concurrency`). Two separate `smoke` commands may run at the same time; each deletes only its own tree snapshot.
- **Portage sandboxes.** All six Portage sandbox features are on. Compile phases run as `portage` (uid/gid 250) in their own network namespace, with no loopback, because Docker drops `CAP_NET_ADMIN`. This rules out anything that talks TCP during a compile.
- **Eclasses.**
  - `go-module.eclass` exports `GOCACHE="${T}/go-build"` at global scope.
  - `go-env.eclass` sets `GOFLAGS` (`-x -v -modcacherw -buildvcs=false`, plus `-buildmode=pie`) when the compile environment is set up. There is no `-trimpath`.
  - `zig.eclass` sets `ZIG_GLOBAL_CACHE_DIR` under `${T}` in `pkg_setup`.
  - `econf` appends `EXTRA_ECONF` last and `eval`s it when it runs (`phase-helpers.sh`).
- **Portage `FEATURES=ccache`.**
  - It prepends `/usr/lib/ccache/bin` to `PATH`.
  - It runs `addwrite "${CCACHE_DIR}"`.
  - It fixes `CCACHE_DIR`'s group to `portage` and its mode to setgid.
  - It exports `CCACHE_DISABLE=1` when the feature is off.
  - If ccache is not installed, it warns and drops the feature.
- **Docker.**
  - `--mount type=volume,…,volume-subpath=` requires Engine 26 or newer; smoke already requires 28.0.
  - The subpath must exist before the container starts. `docker create` accepts a missing subpath; `docker start` then fails with `cannot access path …` (verified on Engine 29.9).
  - Named volumes live on Docker's root filesystem, which on the operator's host is an 8 GB volume.
- **Overlay mix.** 21 Cargo, 6 Go, and 0 autotools/cmake/meson packages. The C/C++ and configure caches mostly serve Gentoo dependencies built from source in the dependencies step, and C compiled by cc-rs and cgo.

## Goals / Non-Goals

**Goals:**
- Cache layout and ownership such that a build can never write outside its own package's cache, or into anything that changes how later builds read the cache.
- All decisions (cleanup, budget, reset, reporting) are made in pure Haskell from data gathered by small containers, so they are unit-testable without Docker.
- One container mount per run; no daemons; nothing that needs the network during compile phases.

**Non-Goals:**
- Tuning per-ebuild compatibility, such as package lists that disable ccache. Ebuilds that need it already opt out themselves (for example by exporting `CCACHE_DISABLE=1`).
- Any change to how the dependencies and package emerge steps are invoked, beyond environment and Portage configuration.

## Decisions

### Volume layout and ownership

The volume is `mndz-smoke-compile-cache`. Each run mounts subpath `<category>/<package>` at `/var/cache/mndz-compile`:

```
<category>/<package>/            root:root    0755   (build cannot write here)
  .last-used                     root:root    0644   epoch seconds, written by the run's root setup
  ccache/  go/  autoconf/  zig/  root:portage 2775   (build caches)
```

- The package directory and `.last-used` are not writable by `portage`, so a build cannot forge its own last-used time or add files beside the caches.
- One volume with per-package subdirectories, rather than one volume per mechanism, keeps it to one mount per run and lets cleanup remove a package's caches in one operation.
- *Alternatives:*
  - Host bind under the XDG cache: files would be owned by uid 250 on the host, and `/home` is nearly full.
  - A volume per package: Docker volume sprawl, and no single place to measure the total.

### Helper container for preparation, cleanup, and reset

A short-lived container from the smoke image prepares, cleans, and resets the cache:
- It runs as root with `--network none`, mounting the **whole** volume at `/cache`.
- It runs only scripts rendered by the program; no package code runs in it.
- It carries the product and run labels used for smoke containers, so existing orphan handling applies.

Per command, before the first run:
1. **Inspect.** One `docker run` prints, for each `<category>/<package>`: its size (`du -sb`) and `.last-used`. It also prints the filesystem's available and total bytes (`df -B1`). Measuring free space inside the helper reports the filesystem that actually backs the volume, with no host-side Docker path discovery.
2. **Plan, in pure Haskell** (a new `Smoke.CompileCache` module).
   - Inputs: the inventory keys, the reset set (selected packages under `--reset-compile-cache`), the inspection result, now, and the budget.
   - Output: the package directories to remove, plus the directories to create for the selected packages.
   - Order:
     1. Reset set.
     2. Packages not in inventory.
     3. Packages with `.last-used` older than 30 days.
     4. Least recently used packages until total ≤ effective budget, skipping any used within 24 h.

     A missing `.last-used` counts as never used.
   - Effective budget = `min(max-size, total + available − 2 GiB)`, floored at 0.
3. **Apply.** One `docker run` removes the planned directories, creates the missing package directories with the ownership above, writes `.last-used` for every package with a run in this command, and prunes kept caches: `go/??/*-[ad]` with mtime older than 30 days, and files under `zig/` with mtime older than 30 days. (Zig was planned by atime; Docker's volume filesystem on the operator's host is mounted `noatime`, so atime never moves. See Verification results.)

Writing `.last-used` at apply time, not only when each run starts, matters for long commands: a package whose run comes hours after cleanup would otherwise look idle (or never used, if just created) to a concurrent command's cleanup, which could delete its directory; the run container would then fail to start because its volume subpath is gone.

`--reset-compile-cache` resets every selected package, but directories are created and stamped only for packages with at least one run (a package whose ebuilds are all skipped gets none). With `--no-compile-cache`, reset runs the apply helper with only the removals: no inspection, creation, stamping, or pruning.

Cleanup runs under a host-side lock file at `<cache>/mndz/overlay-manager/smoke/compile-cache.lock`, using `Update.FileLock`. Two `smoke` commands therefore never clean at the same time. Together with the 24 h rule, a command cannot remove a cache another command is using.

If any helper step fails, `smoke` logs a warning and the whole command runs as with `--no-compile-cache`. A broken cache must never block smoke testing.

### Run container wiring (compile cache on)

- **Create arguments.** One more mount: `type=volume,src=mndz-smoke-compile-cache,dst=/var/cache/mndz-compile,volume-subpath=<category>/<package>`.
- **Root setup script.** In addition to what it writes today:
  - `/etc/mndz-ccache.conf` (root, 0644):

    ```
    cache_dir = /var/cache/mndz-compile/ccache
    compiler_check = %compiler% -v
    hash_dir = false
    base_dir = /var/tmp/portage
    umask = 002
    max_size = <per-package size>
    ```

  - `make.conf` lines:
    - `FEATURES` gains `ccache`.
    - `CCACHE_DIR=/var/cache/mndz-compile/ccache`.
    - `CCACHE_CONFIGPATH=/etc/mndz-ccache.conf`, so it is the only config file read.
    - The same settings again as `CCACHE_*` environment variables. The environment outranks any config file, so a `ccache.conf` a build drops in its cwd tree cannot override them.
    - `CCACHE_STATSLOG=/var/tmp/mndz-ccache-stats.log`, for per-run statistics outside the cache. The setup script creates it empty as root:portage 0664, and the bashrc hooks `addwrite` it, because Portage's ccache support only adds `CCACHE_DIR` to the sandbox's write list.
  - `MNDZ_SMOKE_LANE=<plain|tilde|none>`.
  - `/etc/portage/bashrc` with the user phase hooks below.
  - `.last-used` with the current epoch.
- **Per-package ccache size.** `min(1 GiB, effective budget)`. Do not set `CCACHE_SIZE`: Portage would run `ccache -M` in every phase and try to rewrite the read-only config.

`/etc/portage/bashrc` defines `pre_src_<phase>` hooks for `unpack`, `prepare`, `configure`, `compile`, `test`, and `install`. Each hook calls one shared function that:
- **Go**, when `GOCACHE` is set (go-module or golang-base packages):
  - exports `GOCACHE=/var/cache/mndz-compile/go` and runs `addwrite` on it;
  - appends ` -trimpath` to `GOFLAGS` once, guarded so it is not appended repeatedly. `go-module_src_configure` resets `GOFLAGS` after `pre_src_configure`, so `-trimpath` takes effect from `pre_src_compile` on: compile, test, and install;
  - writes `$(date +%s)` to `go/trim.txt` via temp file and rename.
- **Zig**, when `ZIG_GLOBAL_CACHE_DIR` is set: points it at `/var/cache/mndz-compile/zig` and runs `addwrite`.
- **Configure** (`pre_src_configure` only):
  - adds `--cache-file=${T}/mndz-confcache/\${ABI:-default}` to `EXTRA_ECONF`. The escaped `${ABI}` expands when `econf` evals it, so each multilib ABI gets its own file;
  - copies existing caches from `autoconf/<CATEGORY>/<PN>/<lane>/` into `${T}/mndz-confcache/`;
  - writes a marker, `/var/tmp/mndz-confcache-used/<CATEGORY>_<PN>`. The setup script creates that directory root:portage 2775, and the hook `addwrite`s it and `autoconf/`.

`post_src_configure` filters each `${T}/mndz-confcache/*` and writes it back by temp file and rename. The filter drops lines matching `ac_cv_env_*`, `ac_cv_lib_*`, and `ac_cv_path_install`.

Why user phase hooks rather than top-level conditionals in `bashrc`: `bashrc` is sourced before the ebuild and its eclasses on some phases. Hooks run after the eclass exports, immediately before the phase function. A spike with a top-level `src_*` conditional worked for `GOCACHE`; the hooks avoid depending on that sourcing order.

*Alternatives considered for configure caching:* `CONFIG_SITE` sourcing the cache (Gentoo's experimental wiki approach) never writes results back without a second mechanism. `--cache-file` lets configure maintain the file.

### Go trim suppression and its checks

Go skips trimming when `trim.txt` holds a Unix time t with `now − 24h < t < now + 1h`. The hooks write it with the container's own clock before every phase that may run `go`. Cleanup (above) replaces Go's age policy. This depends on an undocumented internal (see proposal), so it is checked in two places with **one shared script** rendered by the library:

1. **Script (POSIX sh).**
   - Environment: `GOENV=off GOTOOLCHAIN=local GOPROXY=off GOFLAGS= GOCACHE=<tmp>`.
   - Steps:
     1. Build module A (imports `encoding/json`).
     2. Backdate every `??/*-[ad]` entry by 10 days.
     3. Copy the cache.
     4. **Treatment:** write `trim.txt` = now, build module B (empty main), and count entries still backdated. The result must be > 0.
     5. **Control** (on the copy): write `trim.txt` = now − 2 days, build B, and count again. The result must be 0. This proves Go would otherwise trim.
   - It prints `ok`, `fail`, or `inconclusive` (the control kept entries).
2. **In the container:**
   - Runs after the dependencies step, before the package step, when `go` is on `PATH` and `go env GOVERSION` has not been checked in this command.
   - Runs as root in `/var/tmp`, offline.
   - `fail` logs the warning and is recorded in metrics. `inconclusive` is logged at info level.
3. **Test suite:** a test runs the same rendered script against the host `go`, and is skipped with a visible note when `go` is absent. It catches a Go upgrade on the development machine before the next smoke command does.

*GOCACHEPROG alternative rejected:* see proposal. If the checks start failing, the documented fallback is a small standard-library-only GOCACHEPROG of our own, not a third-party one.

### Reporting

After the package step (or the failing step), the program runs, as root in the container:
- `ccache --print-log-stats` (the machine-readable form of `--show-log-stats`) with `CCACHE_CONFIGPATH` and `CCACHE_STATSLOG` set, for hits (`direct_cache_hit + preprocessed_cache_hit`) and misses (`cache_miss`) across both emerge steps;
- a count of `go/??/*-a` entries, compared with a count taken by the setup script.

It logs one line per run and records the same numbers in run metrics as a `compile-cache` event. Recorder events carry no parent, so the event names the run's span id and atom. Per command, it records the cleanup result: size before and after, and packages removed.

Configure-failure note: when the failing step's log contains `failed (configure phase)` and `/var/tmp/mndz-confcache-used/` holds a marker, the run's logged error gains a sentence naming the configure cache and `--no-compile-cache`.

### Smoke image recipe

- `ENV FEATURES="getbinpkg buildpkg"`.
- The Portage `RUN` adds `--mount=type=cache,id=mndz-smoke-build-binpkgs,target=/var/cache/binpkgs`.
- The final emerge installs `sys-process/time dev-util/ccache`. ccache is on the binhost and already depends on `dev-util/shadowman`, which creates `/usr/lib/ccache/bin`.
- `smokeGeneratorId` becomes `mndz-overlay-manager-smoke-2`, so existing hosts rebuild once.

### Config key

`smoke-compile-cache-max-size` is a string such as `3GiB`, `512MiB`, or `1073741824`. A new pure parser handles it alongside the duration parser in `Config.Types`. The default is 3 GiB. Errors use the same message shape as duration keys.

## Verification results

Recorded from spikes on the operator's host (Docker Engine 29.9, btrfs `/var/lib/docker` mounted `noatime`; smoke image `mndz-overlay-manager-smoke-1` plus ccache 4.13.5 and go 1.27.3 from the binhost).

- **1.1 Volume subpath and ownership.** A scratch volume with `dev-util/crush` root:root 0755 and `ccache/ go/ autoconf/ zig/` root:portage 2775 was mounted through `volume-subpath`. As `portage`: writing in each subdirectory succeeded; creating a file in the package directory, writing `.last-used`, and renaming a subdirectory were denied. `ls ..` from the mount point showed the container's own `/var/cache`, not other packages. `FEATURES=ccache` with `CCACHE_DIR` in the subpath was accepted and stored results there. A missing subpath does **not** fail `docker create`; `docker start` fails with `cannot access path`. Preparing the directory before creating the container (as designed) covers both.
- **1.2 Go.** With the `pre_src_*` hooks, `app-misc/gojq-0.12.17` (`FEATURES="test test-fail-continue"`; one upstream test fails on Go 1.27 regardless of the cache) showed `GOCACHE=/var/cache/mndz-compile/go`, `GOFLAGS=… -buildmode=pie -trimpath`, and a fresh `trim.txt` after compile and install. The first build stored 839 `-a` entries. The second build added 0 entries and ran no `compile` commands in compile, test, or install, so all three phases read the persistent cache with the same flags.
- **1.3 Configure cache.** `sys-apps/which`: the first configure printed 4 `(cached)` lines, the second 64. The saved `autoconf/sys-apps/which/plain/amd64` has 78 lines and no `ac_cv_env_`, `ac_cv_lib_`, or `ac_cv_path_install` entries. `dev-libs/libffi` with `abi_x86_32` configured with `--cache-file=…/mndz-confcache/amd64` and `…/x86`, and saved one file per ABI.
- **1.4 ccache configuration.** With `CCACHE_CONFIGPATH=/etc/mndz-ccache.conf` and the `CCACHE_*` environment, a `ccache.conf` containing `disable = true`, `cache_dir`, and `max_size` planted in the cache directory and in a build-tree directory (`ccache.conf` and `.ccache.conf`) was ignored: `ccache -p` showed every setting from the environment or default, and `ccache -s -v` showed only `/etc/mndz-ccache.conf`. `ccache --show-log-stats` needs `CCACHE_STATSLOG` (and `CCACHE_CONFIGPATH`) in its own environment; it printed 1 hit / 33 misses for the first `which` build and 5 hits / 0 misses for the second.
- **1.5 atime.** On the volume, a file backdated to atime −10 days kept that atime after two reads (`noatime`). Zig pruning therefore uses mtime, like Go. (Go refreshes an entry's mtime when it uses it; Zig may not, which only makes Zig entries expire earlier.)

## Risks / Trade-offs

- [Go stops honoring `trim.txt`, for example via the Go 1.28 trimming work] → Builds still succeed, cross-run hits drop, and both checks report it. Fallback: our own GOCACHEPROG.
- [A malicious build poisons its own package's cache for later versions] → Accepted. Poisoning is limited to that package by the subpath; `--reset-compile-cache` clears it; 30-day expiry bounds its lifetime.
- [Configure cache gives a wrong cached answer, causing a false failure or a silently different build] → Per-lane and per-ABI keys and the filter list; the failure note points at `--no-compile-cache`. Only Gentoo dependencies use it in practice.
- [`--cache-file` passed to a non-autoconf script that `econf` wraps] → It fails loudly in `src_configure`, and the failure note names the cache.
- [Zig entries pruned by mtime, because the volume filesystem is mounted `noatime`] → An entry Zig keeps reusing without rewriting is pruned 30 days after it was written. That costs only hits; there is no correctness impact.
- [Per-package caches duplicate the Go standard library across 6 Go packages, about 75 MB each] → Accepted for isolation; it counts against the budget.
- [The budget is small on hosts with little Docker disk] → Fewer hits; the formula never fills the disk.
- [ccache masquerade wraps compiles in packages that detect ccache badly] → Those ebuilds already opt out with `CCACHE_DISABLE`; `--no-compile-cache` remains for the rest.

## Migration Plan

- The first `smoke` after upgrade rebuilds the smoke image (generator id) and creates `mndz-smoke-compile-cache` on first use. No operator action is needed.
- Rollback: run with `--no-compile-cache`, or `docker volume rm mndz-smoke-compile-cache`. Older program versions ignore the volume.
