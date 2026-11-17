# Tasks

## 1. Verify unproven container behavior

- [x] 1.1 In a container from the current smoke image with `SYS_ADMIN`, mount a scratch volume through `volume-subpath` holding a root:root 0755 package directory with root:portage 2775 `ccache/ go/ autoconf/ zig/` subdirectories. Done when design.md records that: a `portage`-user build can write the subdirectories but not the package directory or `.last-used`; Portage `FEATURES=ccache` accepts `CCACHE_DIR` there; and a missing subpath fails `docker create`.
- [x] 1.2 With the design's `/etc/portage/bashrc` `pre_src_*` hooks (no top-level conditionals), emerge one go-module package twice. Done when design.md records that `GOCACHE`, `-trimpath`, and `trim.txt` take effect in compile, test, and install, and the second build adds few cache entries.
- [x] 1.3 Emerge one autotools Gentoo package from source twice with the `EXTRA_ECONF --cache-file=${T}/mndz-confcache/\${ABI:-default}` hook and the `post_src_configure` filter, then once more with a multilib ABI if one is at hand. Done when design.md records that the second configure prints `(cached)` lines, the saved file has no `ac_cv_env_`/`ac_cv_lib_`/`ac_cv_path_install` entries, and each ABI has its own file.
- [x] 1.4 With `CCACHE_CONFIGPATH` pointing at a root-owned file, the `CCACHE_*` environment, and `CCACHE_STATSLOG`, build a C package. Done when design.md records that a `ccache.conf` written into the cache and into the build tree is ignored, and that `ccache --show-log-stats` (the binhost ccache version) prints per-run hits and misses.
- [x] 1.5 Check `stat -c %X` on a file in a Docker volume after reading it twice, a day apart or with backdated times. Done when design.md records whether atime moves on this host's volume filesystem, and the Zig pruning rule switches to mtime if it does not.

## 2. Size config key

- [x] 2.1 Add the `smoke-compile-cache-max-size` byte-size parser and config field (default 3 GiB) in `Config.Types`. Verify with `test/Test/Config.hs` cases for `3GiB`, `512MiB`, `1KiB`, a plain byte count, the default when omitted, and a configuration error for `"lots"` and for negative values.
- [x] 2.2 Document the key and its default in the README config section. Verify by reading the README key list against `Config.Types`.

## 3. Smoke image recipe

- [x] 3.1 In `Smoke.Recipe`:
  - set `FEATURES="getbinpkg buildpkg"`;
  - add the `mndz-smoke-build-binpkgs` cache mount on the Portage `RUN`;
  - install `dev-util/ccache` with `sys-process/time`;
  - bump `smokeGeneratorId` to `mndz-overlay-manager-smoke-2`.

  Verify with recipe tests that cover each point, that no cache mount id appears in the materialize recipe, and that no sandbox feature is removed.
- [x] 3.2 Build the smoke image on this host via `smoke` and verify that `ccache --version` works in a container from it, and that a second build after removing the image installs any compiled package from the binpkgs mount.

## 4. Go trim suppression check

- [x] 4.1 Add the rendered POSIX sh check script (treatment and control, printing `ok`, `fail`, or `inconclusive`) to the new `Smoke.CompileCache` module. Its haddock must state that `trim.txt` is an undocumented `go` internal, cite golang/go#69565, #69879, and #81830, and name the fallback (our own stdlib-only GOCACHEPROG). Verify with a pure test of the rendered script's key lines.
- [x] 4.2 Add a test-suite test that runs the rendered script with the host `go` in a temporary directory and expects `ok`. It is skipped with a visible message when `go` is not on `PATH`. Verify it passes with go 1.27.4 and is reported as skipped with `PATH` lacking `go`.
- [x] 4.3 Document in the README that the Go cache relies on this fragile mechanism, what the warning means, and that builds still succeed (`project-docs`). Verify against the spec scenario "Trim check warning".

## 5. Cleanup and budget planning (pure)

- [x] 5.1 In `Smoke.CompileCache`, add the parser for the inspect helper's output: per-package size and last-used, plus filesystem available and total bytes. Verify with tests on sample output, including a package with no `.last-used` and a malformed line.
- [x] 5.2 Add the cleanup planner:
  - removal order: reset set, then not in inventory, then 30-day idle, then LRU to the effective budget;
  - the 24 h protection and its over-budget warning;
  - the effective budget formula `min(max-size, total + available − 2 GiB)`;
  - the directories to create for the selected packages.

  Verify with unit tests for every scenario of the `smoke-compile-cache` requirements "Compile cache cleanup at start", "Compile cache use is recorded", "Compile cache size budget", and "Resetting compile caches".

## 6. Helper container and locking

- [x] 6.1 Render and run the inspect and apply helper commands. Each is a `docker run --rm --network none` from the smoke image, with labels and the whole volume at `/cache`. Apply covers removals, package directory creation with the design's ownership, and pruning of Go (mtime) and Zig entries older than 30 days. Hold `<cache>/mndz/overlay-manager/smoke/compile-cache.lock` via `Update.FileLock` around inspect, plan, and apply. Verify with fake-runner tests of the argv and script content, and a test that a held lock delays a second cleanup.
- [x] 6.2 On any helper failure, log one warning and switch the command to no-compile-cache mode. Verify with a fake-runner test where the inspect container exits non-zero and the run containers are created without the cache mount.

## 7. Run container wiring

- [x] 7.1 Extend `smokeCreateArgs` with the `volume-subpath` mount when the cache is on. Verify with argv tests for on and off, including that off has no `mndz-smoke-compile-cache` mount and that the existing capability and seccomp assertions still hold.
- [x] 7.2 Extend `setupScript` and the Portage configuration with:
  - `/etc/mndz-ccache.conf`;
  - the `make.conf` ccache lines and `CCACHE_*` environment;
  - `CCACHE_STATSLOG`;
  - `MNDZ_SMOKE_LANE`;
  - the `/etc/portage/bashrc` hooks for Go, Zig, and the configure cache;
  - `.last-used`;
  - the initial Go entry count.

  Verify with pure tests of the rendered files for a plain-lane Go run, a tilde-lane run, an unlabeled run, and a run with the cache off (no ccache feature, no bashrc hooks).
- [x] 7.3 Run the Go trim check after the dependencies step when `go` is on `PATH` and its version is unchecked in this command. Map `fail` to a warning and `inconclusive` to info. Verify with fake-runner tests: two runs with the same Go version check once, and a `fail` result leaves the run's outcome unchanged.
- [x] 7.4 Document the `mndz-smoke-compile-cache` volume, its per-package layout and caches, cleanup rules, and manual whole-volume removal in the README smoke environment section, and confirm `eclean` does not touch the volume. Verify with a test that `eclean`'s docker calls never name the volume, and by reading the README against the `project-docs` delta.

## 8. CLI flags

- [x] 8.1 Add `--no-compile-cache` and `--reset-compile-cache` to the `smoke` parser, and wire them through `Smoke.Run`:
  - reset deletes the selected packages' caches before the first run, even with `--no-compile-cache`;
  - unknown targets still fail before any deletion;
  - no-compile-cache skips cleanup and mounts.

  Verify with `test/Test/CLI.hs` parser tests and fake-runner tests for each `smoke-command` and `smoke-compile-cache` reset/opt-out scenario.
- [x] 8.2 Update `smoke --help` text and README `smoke` section for both flags. Verify with the help test for the "Compile cache flags in help" scenario.

## 9. Reporting and metrics

- [x] 9.1 After each run with the cache on, collect `ccache --show-log-stats` and the Go entry count, and log the one-line report with atom and lane. Verify with a fake-runner test of the logged line and that stdout result lines are unchanged.
- [x] 9.2 Record per-run `compile-cache` metrics and per-command cleanup metrics: size before and after, packages removed, and the trim check result with its Go version. Verify with `test/Test/Metrics.hs`-style tests for each `run-metrics` delta scenario, including no events under `--no-compile-cache`.
- [x] 9.3 Add the configure-cache note to a run's failure error when the failing step's log shows `failed (configure phase)` and a confcache marker exists. Verify with a fake-runner test for the "Stale configure cache" scenario and one without a marker.

## 10. Integration

- [x] 10.1 On this host, run `smoke` twice for one Go package (e.g. `crush`) and for one package whose dependencies compile C from source. Verify that:
  - the second command's report shows ccache hits and few new Go entries;
  - its package step is faster;
  - the Go trim check passes;
  - `docker volume inspect mndz-smoke-compile-cache` shows only the selected packages' directories.
- [x] 10.2 Run `smoke --reset-compile-cache crush` and `smoke --no-compile-cache crush`. Verify the reset empties only crush's cache, and the opt-out run has no cache mount and no report line.
- [x] 10.3 Merge the delta specs into `openspec/specs/` (new `smoke-compile-cache`; modified `smoke-command`, `smoke-environment`, `smoke-image`, `run-metrics`, `cli-help`, `project-docs`), scrub change-delta wording, and run `openspec validate --strict` and `just check`. Done when both are green.

## Workflow follow-up

- Archive the change after review.
- Then check that `sccache-rust-compile-cache-handoff.typ` and `build-run-cache-sharing-handoff.typ` still describe this change's volume and layout accurately.
