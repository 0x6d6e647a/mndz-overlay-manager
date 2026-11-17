# Proposal

## Why

Every overlay package has been checked by hand: `sudo emerge` on the operator's own machine, then a few commands typed from the seed spec. That proves little about a clean system, runs as real root, depends on what the host already has installed, and is not repeated when an ebuild changes. The manager now owns a verified Gentoo tree and already drives Docker containers, so it can install each ebuild in a clean container with Portage's sandboxes on and run the package's checks itself.

## What Changes

- **New `smoke` work command.** It takes `PACKAGE...` targets and `--exclude` like `outdated`, and has no `--refresh`. For every selected package it tests every ebuild version on disk, one at a time, in a fresh container. It prints one result line per run and a summary, keeps going after a failure, and exits `1` when any run failed.
- **Runs follow runtime lanes.** A DepsAndAssets ebuild is installed with its runtime (for example `dev-lang/go`) capped at the lane ceiling it serves, read from the managed tree and the ebuild's own runtime floor. An ebuild that serves both the plain and the tilde lane gets one run per distinct ceiling. Nothing is fetched from upstream and nothing in the overlay is written.
- **A clean, distinct environment.** A separate smoke image (stage3, Portage upgrade, `@world` update, GNU time, nothing else) with its own tag and sidecar. Containers get `CAP_SYS_ADMIN` and nothing more, so Portage's network, IPC, and PID sandboxes stay on. The run hard-fails before any emerge when the sandboxes cannot be created.
- **Tree snapshot per run.** `smoke` imports the managed tree into a per-run Docker image, mounts it read-only into every container of that run, and deletes it at exit. The tree lock is released as soon as the snapshot exists, so a long smoke run does not block tree syncs in other commands.
- **The package under test is built from source and fetched fresh.** Dependencies install first, from the Gentoo binhost and a smoke-owned binary-package volume. Then the ebuild under test is emerged from source with an empty distfiles directory, so a dead download URL fails the run. Overlay dependencies are also built from source.
- **Checks are defined per package in the program.** Each package has named checks: commands run in the container as a non-root user, with expectations on exit status and output. The floor is a version or help check; packages whose seed spec describes a richer smoke get that one. Checks run without network unless they declare they need it. A selected package with no smoke definition is a hard failure.
- **Logs only on failure.** Containers are always removed. Portage output and every check's output are saved under the manager cache, and the summary prints the path.
- **`--jobs` sets build parallelism for `smoke`.** `MAKEOPTS="-j<jobs> -l<jobs+1>"` in the container, with one emerge job.
- **Materialize recipe stops opting out of Portage sandboxes.** `-ipc-sandbox -network-sandbox -pid-sandbox` are removed from the generated recipe's `FEATURES`. Protection during `docker build` is unchanged (Docker denies the namespaces either way); the image is rebuilt once.
- **Host requirements.** `smoke` needs `git`, `gpg`, and `docker`. **Docker must be 28.0 or newer with the containerd image store**, because image mounts are not available on the classic storage drivers.
- **Docs.** README gains a `smoke` section and a runtime-requirements row. Help lists the command.

## Capabilities

### New Capabilities

- `smoke-command`: the `smoke` work command. Covers the CLI surface, package selection, which runs exist for each ebuild version (lane ceilings and floors), sequencing, result lines, summary, exit status, logs, and preflight.
- `smoke-image`: the smoke image. Covers its generated recipe, tag, sidecar, when it is built or rebuilt, and pruning of the previous image.
- `smoke-environment`: the container each run uses. Covers the per-run tree snapshot, mounts, privileges and the sandbox probe, keyword and mask configuration, the two emerge steps, binary-package and distfiles storage, and network attachment.
- `smoke-checks`: per-package smoke definitions. Covers the rule that every package has one, the floor check, checks taken from seed specs, how a check runs (user, timeout, network, expectations), and how results are decided.

### Modified Capabilities

- `gentoo-tree`: `smoke` joins the commands that sync. A reader's shared lock lasts until exit, except `smoke`, which releases it once its tree snapshot exists. The consumer list names smoke containers.
- `ensure-materialize-image`: the generated recipe no longer disables Portage's namespace sandboxes in `FEATURES`.
- `package-exclude`: `smoke` accepts `--exclude`.
- `cli-help`: top-level help lists `smoke`; `smoke --help` documents targets and `--exclude` and has no `--refresh`.
- `cli-concurrency`: for `smoke`, `--jobs` sets the build parallelism inside the container, and runs are never concurrent.
- `run-metrics`: `smoke` records a run; commands in smoke containers are measured like materialize container commands.
- `disk-space-preflight`: a smoke image build is gated on Docker storage free space like a materialize image build.
- `project-docs`: README documents `smoke` and its host requirements.
- `test-coverage`: the suite exercises smoke planning, the smoke container adapter, and the check interpreter with fakes.

## Impact

- Code: new modules for smoke planning, the smoke image recipe and ensure, the tree snapshot, the smoke container session, the check framework, and the per-package definitions. Touches `CLI.Parser` (new command, `commandTreeSync`), `app/Main.hs` (dispatch, wiring), `Update.GentooTree` (release before exit), `Update.Materialize.Recipe` and `Update.Materialize.Sidecar` (FEATURES line, generator identity), `Update.Process.Docker` (shared labels and sweep), `Update.EbuildEdit` or a sibling (runtime floor readers for Go, Node.js, SBCL, and Python slots), `Metrics.Startup` and `Metrics.Run` (command name), `Update.Preflight` (Docker version and image store).
- Tests: new unit tests for run planning, floor readers, recipe render, container argv, the check interpreter, and a test that the smoke map covers exactly the hardcoded policy keys. Existing recipe tests change with the FEATURES line.
- Docker: one more image (`mndz-overlay-manager/smoke:local`), a short-lived tree image per run, two named volumes (binary packages and dependency distfiles), and one container per run. The first `smoke` builds the image (minutes).
- Disk: about 670 MB in Docker storage while a run is in progress (tree snapshot), plus the smoke image and volumes. Logs under the manager cache.
- Network: emerges fetch from the Gentoo binhost and from each ebuild's `SRC_URI` on every run.
- Operator-visible: a new command; one materialize image rebuild after upgrade; a Docker version and image-store requirement that applies to `smoke` only.
- Docs: `README.md` runtime requirements, a `smoke` section, cache layout.

## Non-goals

- `--refresh` on `smoke`. It syncs the tree only when a sync is due.
- A pass cache. Every run rebuilds. Remembering passes is a separate follow-up change.
- Making a passing smoke a gate for `update`.
- Package version scoping such as `=dev-lang/bun-42`. PV is not a CLI argument; `smoke` tests every on-disk version of the selected packages.
- USE-flag variants and running `src_test`.
- Architectures other than the host's.
- Pruning the smoke binary-package and distfiles volumes. The README names them; removal is manual.
- Per-ebuild free-space estimates for builds inside the container.
- Changing the smoke requirements in seed specs. They stay the source for richer checks.
- Enabling the BuildKit `security.insecure` entitlement, or any other way to sandbox emerges during `docker build`.
