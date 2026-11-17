# smoke-compile-cache Specification

## Purpose

Keep compiler and configure results from `smoke` builds between runs, isolated per package, so repeated builds of the same overlay package reuse earlier work without one package being able to influence another's builds.

## Requirements

### Requirement: Per-package compile cache volume

Unless `--no-compile-cache` is given, each smoke run container SHALL mount the subdirectory `<category>/<package>` of the Docker volume `mndz-smoke-compile-cache`, for the package under test, as its compile cache. The volume SHALL persist across smoke commands. The container SHALL NOT see any other part of the volume.

#### Scenario: Cache persists across commands

- **WHEN** `smoke crush` runs twice, in two separate commands
- **THEN** both runs mount the same `dev-util/crush` part of `mndz-smoke-compile-cache`

#### Scenario: Other packages are not visible

- **WHEN** a process in the run container for `dev-util/crush` lists or opens paths outside its compile cache directory
- **THEN** it cannot reach the cache of any other package

### Requirement: Compile cache directories are prepared before the run

Before creating a run container, `smoke` SHALL ensure the package's cache directory exists in the volume, writable by Portage's build user, using a container that runs only the program's own commands. A run SHALL NOT fail because its cache directory did not exist yet.

#### Scenario: First smoke of a package

- **WHEN** `smoke beads` runs and the volume has no `dev-util/beads` directory
- **THEN** the directory is created before the run container is created
- **AND** the build can write to it

### Requirement: Dependencies share the run's cache

Packages built from source in a run's dependencies step SHALL use the compile cache of the package under test.

#### Scenario: Dependency compiled in a run

- **WHEN** the dependencies step of `dev-util/node-gyp`'s run compiles a Gentoo dependency from source
- **THEN** that dependency's compiler results are stored in the `dev-build/node-gyp` cache

### Requirement: C and C++ compiles are cached

Smoke builds SHALL cache C and C++ compiler results with ccache in the package's compile cache. A cached result SHALL remain usable after the smoke image is rebuilt with the same compiler version, and after a version or revision bump of the package when the compiled sources and flags are unchanged.

#### Scenario: Rebuild of the same version

- **WHEN** a C package is smoke-built twice with no change
- **THEN** the second build's compiles are ccache hits

#### Scenario: Revision bump

- **WHEN** `cat/pkg-1.0-r1` was smoke-built and then `cat/pkg-1.0-r2` with the same sources and flags is built
- **THEN** the second build's compiles are ccache hits

### Requirement: ccache settings cannot be changed by a build

ccache SHALL read its configuration only from a file outside the compile cache that the build cannot write. Settings in a file a build writes into the cache SHALL have no effect on later builds.

#### Scenario: Build writes a cache configuration file

- **WHEN** a build writes a `ccache.conf` into its compile cache directory
- **THEN** later builds of that package ignore it

### Requirement: Go build results are cached

Smoke builds of Go packages SHALL keep Go's build cache in the package's compile cache and SHALL build with path trimming, so results are reused across smoke commands and across version or revision bumps whose sources are unchanged.

#### Scenario: Second smoke of a Go package

- **WHEN** a Go package is smoke-built twice in separate commands
- **THEN** the second build reuses cached Go results and adds few new cache entries

### Requirement: Go does not trim the persistent cache

Go's automatic trimming of build cache entries unused for five days SHALL NOT run against the compile cache during smoke builds. Cache age SHALL be managed only by smoke's own cleanup.

#### Scenario: Weeks between smoke commands

- **WHEN** a Go package was last smoke-built 20 days ago and is built again
- **THEN** cache entries from the earlier build that this build does not reuse are still present after it

### Requirement: Go trim suppression is checked

When the compile cache is on, the first time a smoke command builds with a given Go version, it SHALL check in the container that Go's trimming is still suppressed. A failed check SHALL log a warning naming the Go version, SHALL be recorded in run metrics, and SHALL NOT change the run's outcome or turn off the cache.

#### Scenario: Go stops honoring the suppression

- **WHEN** a newer Go version trims the cache despite the suppression
- **THEN** `smoke` logs a warning that Go cache trimming is not suppressed for that version
- **AND** the run's result is decided as if the check had passed

#### Scenario: Same Go version twice

- **WHEN** two runs in one command install the same Go version
- **THEN** the check runs once

### Requirement: Configure results are cached per package, ABI, and lane

For packages configured through Portage's `econf`, smoke builds SHALL load and save autoconf results in a cache kept per built package, ABI, and lane inside the run's compile cache. Results about the environment, libraries, and the install program SHALL NOT be cached.

#### Scenario: Plain and tilde lanes

- **WHEN** a dependency is configured in the plain-lane run and again in the tilde-lane run
- **THEN** each lane uses its own configure cache

### Requirement: Configure failures name the configure cache

When a run fails in a `src_configure` phase that used a configure cache, the run's error output SHALL state that a configure cache was in use and that `--no-compile-cache` runs without it.

#### Scenario: Stale configure cache

- **WHEN** a dependency's `src_configure` fails during a run with the configure cache in use
- **THEN** the logged failure for that run mentions the configure cache and `--no-compile-cache`

### Requirement: Zig results are cached

Smoke builds of packages that use Portage's Zig support SHALL keep Zig's global cache in the package's compile cache.

#### Scenario: Zig package rebuilt

- **WHEN** a Zig package is smoke-built twice in separate commands
- **THEN** the second build finds the first build's Zig cache entries

### Requirement: Compile cache cleanup at start

At the start of every `smoke` command that uses the compile cache, before the first run, the program SHALL remove, in order: caches of packages no longer in the overlay inventory; caches unused for 30 days; then the least recently used packages' caches until the total fits the budget. In kept caches it SHALL delete Go and Zig entries unused for 30 days.

#### Scenario: Package removed from the overlay

- **WHEN** `dev-util/old` is no longer in the overlay and its cache exists
- **THEN** its cache is removed before the first run

#### Scenario: Over budget

- **WHEN** the caches total 4 GiB and the budget is 3 GiB
- **THEN** whole package caches are removed, least recently used first, until the total is at most 3 GiB

### Requirement: Compile cache use is recorded

A package's cache SHALL count as used when a run starting with that cache begins. Cleanup SHALL NOT remove for age or budget a cache used within the last 24 hours, so it never removes a cache that a concurrent smoke command is using. When only such caches remain over budget, it SHALL log a warning.

#### Scenario: Concurrent command

- **WHEN** one `smoke` command is building `dev-util/crush` and a second command's cleanup finds the caches over budget
- **THEN** the `dev-util/crush` cache is not removed

### Requirement: Compile cache size budget

The budget SHALL be the config key `smoke-compile-cache-max-size`, a byte size with an optional `KiB`, `MiB`, or `GiB` suffix, defaulting to `3GiB`. Cleanup SHALL also lower the budget so that at least 2 GiB stays free on the filesystem holding Docker volumes. An invalid value SHALL be a configuration error.

#### Scenario: Default budget

- **WHEN** the config file has no `smoke-compile-cache-max-size`
- **THEN** cleanup keeps the caches at or below 3 GiB

#### Scenario: Little free space

- **WHEN** the caches use 1 GiB and the volume filesystem has 1.5 GiB free
- **THEN** cleanup removes caches until at least 2 GiB is free

#### Scenario: Invalid size

- **WHEN** the config file sets `smoke-compile-cache-max-size = "lots"`
- **THEN** the program reports a configuration error and exits with status `1`

### Requirement: Cleanup failure disables the cache for the command

When preparing or cleaning the compile cache fails, `smoke` SHALL log a warning naming the cause and SHALL run every run of that command as if `--no-compile-cache` had been given.

#### Scenario: Helper container fails

- **WHEN** the container that cleans the compile cache exits non-zero
- **THEN** `smoke` logs a warning and the runs proceed without a compile cache

### Requirement: Resetting compile caches

With `--reset-compile-cache`, `smoke` SHALL delete the compile caches of every selected package before the first run. Caches of packages that are not selected SHALL be kept.

#### Scenario: Reset one package

- **WHEN** the operator runs `smoke --reset-compile-cache crush`
- **THEN** the `dev-util/crush` cache is empty when its first run starts
- **AND** caches of other packages are unchanged

#### Scenario: Reset with no compile cache

- **WHEN** the operator runs `smoke --reset-compile-cache --no-compile-cache crush`
- **THEN** the `dev-util/crush` cache is deleted and the runs use no compile cache

### Requirement: Running without a compile cache

With `--no-compile-cache`, smoke runs SHALL NOT mount the compile cache volume and SHALL build with ccache disabled and with the Go, configure, and Zig caches left at Portage's per-build defaults. Cleanup SHALL NOT run.

#### Scenario: Opt-out run

- **WHEN** the operator runs `smoke --no-compile-cache crush`
- **THEN** the run container has no `mndz-smoke-compile-cache` mount
- **AND** the build performs no ccache lookups

### Requirement: Per-run compile cache report

After each run that used the compile cache, `smoke` SHALL log one line naming the run's ebuild atom and lane label, with that run's ccache hits and misses, the number of Go cache entries added, and the Go trim check result when one ran. The stdout result line SHALL be unchanged.

#### Scenario: Report after a Go run

- **WHEN** the run of `dev-util/crush-0.101.0` finishes with the compile cache on
- **THEN** a log line for that run reports its ccache hits and misses and its Go cache entries added
