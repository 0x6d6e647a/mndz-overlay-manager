## ADDED Requirements

### Requirement: Package identity and version pin

The seeded package SHALL be `dev-db/badger` at Portage version `4.9.4`, corresponding to upstream GitHub tag `v4.9.4` on `dgraph-io/badger`. The seed SHALL NOT use a newer upstream tag for the initial ebuild.

#### Scenario: Filename and tag

- **WHEN** the seed package is added to the overlay
- **THEN** the ebuild path is `dev-db/badger/badger-4.9.4.ebuild` (or an equivalent revision of PV `4.9.4` only if required for content fixes before first publish)
- **AND** the primary source archive is the GitHub archive for tag `v4.9.4`

### Requirement: Go module and CLI build

The ebuild SHALL inherit `go-module`, declare BDEPEND on a Go version at least as new as the `go` directive in the package’s `go.mod` at that tag, build the CLI with a build of package `./badger`, and install a binary named `badger`.

#### Scenario: Compile and install

- **WHEN** the package is emerged with default USE (jemalloc disabled)
- **THEN** `/usr/bin/badger` is installed and executes successfully for `badger --help`

### Requirement: Vendor assets publish

A Go module-cache vendor tarball named `badger-4.9.4-vendor.tar.xz` with top-level directory `go-mod/` SHALL be published to mndz-overlay-assets as release tag `badger-4.9.4` with checksum sidecars under `dev-db/badger/`. The ebuild SHALL reference that release via a fully parameterized assets `SRC_URI` using `${PV}`.

#### Scenario: Assets URL form

- **WHEN** the ebuild is written
- **THEN** it contains  
  `https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/badger-${PV}/badger-${PV}-vendor.tar.xz`

### Requirement: jemalloc USE private build

The ebuild SHALL offer `IUSE` flag `jemalloc`. When enabled, the ebuild SHALL obtain jemalloc from a fixed upstream source tarball listed in `SRC_URI` (USE-conditional), build it with `--with-jemalloc-prefix=je_`, and link the badger binary with the `jemalloc` Go build tag. The ebuild SHALL NOT depend on `dev-libs/jemalloc` as RDEPEND or BDEPEND for that feature.

#### Scenario: jemalloc disabled

- **WHEN** the package is built with `USE=-jemalloc`
- **THEN** the build does not require a jemalloc tarball fetch for that USE configuration
- **AND** the installed CLI still runs

#### Scenario: jemalloc enabled

- **WHEN** the package is built with `USE=jemalloc`
- **THEN** the build uses the private jemalloc with `je_` prefix and `-tags=jemalloc` (or equivalent)

### Requirement: Shell completion USE flags

The ebuild SHALL offer `bash-completion`, `zsh-completion`, and `fish-completion` USE flags, inherit `shell-completion`, and generate scripts via the installed or just-built `badger` binary using a dummy `--dir` value so PersistentPreRun validation succeeds.

#### Scenario: bash completion generation

- **WHEN** `USE=bash-completion` is enabled during install
- **THEN** a bash completion file for `badger` is installed without requiring a real database directory

### Requirement: test USE gate

The ebuild SHALL include `test` in `IUSE` and set `RESTRICT="!test? ( test )"`. `src_test` SHALL run the package’s Go tests when Portage allows the test phase.

#### Scenario: tests restricted when USE=-test

- **WHEN** `USE=-test` and the package is emerged with `FEATURES=test`
- **THEN** the test phase is restricted and does not run package tests

### Requirement: Operator smoke acceptance

After overlay and assets are published, the operator SHALL verify install by emerging `=dev-db/badger-4.9.4` and running `badger --help` successfully.

#### Scenario: smoke commands

- **WHEN** seed publish is complete
- **THEN** emerge of that atom succeeds
- **AND** `badger --help` exits successfully and lists CLI subcommands
