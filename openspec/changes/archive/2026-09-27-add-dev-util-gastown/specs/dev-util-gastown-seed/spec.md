# dev-util-gastown-seed Specification

## Purpose

Requirements for the seeded `dev-util/gastown` overlay package at upstream 1.1.0 and for the kept `dev-util/beads` 1.0.4 provider ebuild that a Gas Town install selects. This is overlay product truth, not mndz-overlay-manager runtime behavior.

## ADDED Requirements

### Requirement: Gas Town package identity

The seeded package SHALL be `dev-util/gastown` at Portage version `1.1.0`, corresponding to upstream GitHub tag `v1.1.0` on `gastownhall/gastown`. The initial ebuild SHALL be that version, which is one published release behind `1.2.0` and two behind tip `1.2.1`.

#### Scenario: Filename and tag

- **WHEN** the seed package is added to the overlay
- **THEN** the ebuild path is `dev-util/gastown/gastown-1.1.0.ebuild` (or an equivalent revision of PV `1.1.0` only if required for content fixes before first publish)
- **AND** the primary source archive is the GitHub archive for tag `v1.1.0` on `gastownhall/gastown`

### Requirement: Static gt build

The ebuild SHALL inherit `go-module`, set `CGO_ENABLED=0` for the build, compile `./cmd/gt`, and install a single binary named `gt`. The build SHALL pass ldflags that set the reported version to `${PV}` and mark the binary as built by the package. The ebuild SHALL NOT install `gt-proxy-server`, `gt-proxy-client`, or `gt-desktop`. The ebuild SHALL NOT enable CGO or depend on `dev-libs/icu`.

#### Scenario: Default emerge installs gt

- **WHEN** `dev-util/gastown` is emerged with default USE except that `tmux` may be on or off
- **THEN** `/usr/bin/gt` exists and `gt version` reports `1.1.0`
- **AND** `/usr/bin/gt-proxy-server` is absent

#### Scenario: Build does not link ICU

- **WHEN** the emerged `gt` binary is inspected with the system dynamic linker
- **THEN** it does not list `libicui18n`, `libicuuc`, or `libicudata`

### Requirement: Vendor assets

A Go module-cache vendor tarball named `gastown-1.1.0-vendor.tar.xz` with top-level directory `go-mod/` SHALL be published to mndz-overlay-assets as release tag `gastown-1.1.0`. The ebuild SHALL reference that release via a fully parameterized assets `SRC_URI` using `${PV}`.

#### Scenario: Assets URL form

- **WHEN** the ebuild is written
- **THEN** it contains `https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/gastown-${PV}/gastown-${PV}-vendor.tar.xz`

### Requirement: USE flags

The ebuild SHALL offer `bash-completion`, `zsh-completion`, and `fish-completion` without a leading `+`, and `tmux` default-enabled (`+tmux`). `test` SHALL be offered as required by `overlay-test-use`. When a completion flag is enabled, the ebuild SHALL install the script produced by `gt completion` for that shell. When `tmux` is enabled, the ebuild SHALL RDEPEND on `app-misc/tmux`. The ebuild SHALL RDEPEND on `dev-vcs/git`. The ebuild SHALL NOT RDEPEND on an AI agent CLI.

#### Scenario: Bash completion when the flag is on

- **WHEN** the package is emerged with `bash-completion` enabled
- **THEN** a bash completion file for `gt` is installed
- **AND** generating it does not require a Gas Town workspace

#### Scenario: Tmux dependency when the flag is on

- **WHEN** the package is emerged with `USE=tmux`
- **THEN** the package records a dependency on `app-misc/tmux`

#### Scenario: Tmux dependency when the flag is off

- **WHEN** the package is emerged with `USE=-tmux`
- **THEN** the package records no dependency on `app-misc/tmux`

### Requirement: Operator Beads pin and Dolt floor on the seed

The seed ebuild SHALL RDEPEND on `~dev-util/beads-1.0.4` and on `>=dev-db/dolt-1.82.4`. The Beads atom SHALL be the operator pin. The Dolt atom SHALL be the floor declared by tag `v1.1.0` (`MinDoltVersion` `1.82.4`). The ebuild SHALL record a Beads version window of minimum `0.57.0` and no maximum.

#### Scenario: Seed dependency atoms

- **WHEN** `gastown-1.1.0.ebuild` is inspected
- **THEN** its `RDEPEND` includes `~dev-util/beads-1.0.4`
- **AND** its `RDEPEND` includes `>=dev-db/dolt-1.82.4`
- **AND** it records Beads window minimum `0.57.0` with no maximum

### Requirement: Test phase

The ebuild SHALL include `test` in `IUSE` and `RESTRICT="!test? ( test )"`. `src_test` SHALL run the package Go tests in short mode (`ego test -short ./...` or an equivalent failure-checked short Go test invocation).

#### Scenario: Tests skipped when USE=-test

- **WHEN** the package is emerged with `USE=-test` and `FEATURES=test`
- **THEN** Portage skips the test phase

### Requirement: Beads 1.0.4 provider ebuild

The overlay SHALL contain `dev-util/beads/beads-1.0.4.ebuild` (or a revision of PV `1.0.4`) corresponding to GitHub tag `v1.0.4` on `gastownhall/beads`, in addition to the newer Beads tip ebuild. The `1.0.4` ebuild SHALL inherit `go-module`, build `./cmd/bd` with `CGO_ENABLED=1` and the `gms_pure_go` tag, install `/usr/bin/bd`, declare `BDEPEND` of at least Go `1.26.2`, and publish vendor tarball `beads-1.0.4-vendor.tar.xz` on assets release `beads-1.0.4` with a `${PV}` assets `SRC_URI`. It SHALL declare `test` in `IUSE` and `RESTRICT="!test? ( test )"`. Adding this ebuild SHALL leave the newer Beads tip ebuild in place. `SLOT` SHALL remain `0`.

#### Scenario: Both Beads versions are in the tree

- **WHEN** the Beads package directory is listed after the seed
- **THEN** it contains an ebuild for PV `1.0.4` and an ebuild for PV `1.3.0`
- **AND** both use `SLOT="0"`

#### Scenario: 1.0.4 installs bd

- **WHEN** `=dev-util/beads-1.0.4` is emerged
- **THEN** `/usr/bin/bd` reports version `1.0.4`

### Requirement: Install smoke

After the seed ebuilds and assets are published, emerging `=dev-util/gastown-1.1.0` SHALL select Beads `1.0.4`. `gt version` SHALL report `1.1.0`. `gt install` of an empty directory, with `bd` `1.0.4` and a Dolt binary at or above `1.82.4` on `PATH`, SHALL create a headquarters that `gt status` can describe, including a running or startable Dolt server for that town. The smoke SHALL use a throwaway directory and SHALL NOT enable or attach a Mayor session.

#### Scenario: Throwaway town

- **WHEN** the seed is emerged and `gt install` is run against an empty directory with `bd` `1.0.4` and Dolt `2.3.5` on `PATH`
- **THEN** the command exits successfully
- **AND** `gt status` in that directory names the town and Dolt
