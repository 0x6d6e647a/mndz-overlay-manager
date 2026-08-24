# dev-lisp-qlot-seed Specification

## Purpose

Requirements for the manually seeded overlay package `dev-lisp/qlot`: pinned upstream release tarball, private install layout, compile sandbox, LICENSE inventory, KEYWORDS, dependencies, isolation from Autolith, and operator smoke. This is overlay/seed product truth, not mndz-overlay-manager runtime behavior.

## Requirements

### Requirement: Package identity and version pin

The seeded package SHALL be `dev-lisp/qlot` at Portage version `1.8.4`, corresponding to upstream GitHub release tag `1.8.4` on `fukamachi/qlot`. The seed SHALL NOT use a newer upstream tag for the initial ebuild. The live ebuild filename SHALL be `qlot-1.8.4.ebuild` without a `-r0` suffix; content-only fixes before or after first publish SHALL use `-r1` or greater when a revision bump is required.

#### Scenario: Filename and tag

- **WHEN** the seed package is added to the overlay
- **THEN** the ebuild path is `dev-lisp/qlot/qlot-1.8.4.ebuild` (or `qlot-1.8.4-rN.ebuild` only if a content revision is required)
- **AND** the primary source archive is the GitHub release asset `qlot-1.8.4.tar.gz` for tag `1.8.4`

### Requirement: Metadata description homepage and remote-id

The ebuild SHALL set `DESCRIPTION` to a short summary synthesizing upstream README (project-local Common Lisp library installer), `HOMEPAGE` to `https://github.com/fukamachi/qlot`, and `metadata.xml` SHALL declare GitHub remote-id `fukamachi/qlot`.

#### Scenario: Homepage and description

- **WHEN** the ebuild and `metadata.xml` are inspected
- **THEN** the homepage is the GitHub URL above
- **AND** `metadata.xml` contains GitHub remote-id `fukamachi/qlot`

### Requirement: LICENSE inventory of qlot and bundled libraries

The ebuild `LICENSE` field SHALL list Gentoo `licenses/` tokens covering qlot itself (MIT) **and** every Common Lisp library shipped inside the release tarball under `.bundle-libs/software/`. The field SHALL NOT be solely `MIT` when bundled libraries use additional licenses. Token names SHALL match files under Gentoo `licenses/` (or overlay `licenses/` if a token must be added).

#### Scenario: LICENSE is not qlot-only

- **WHEN** the ebuild is inspected after the license inventory
- **THEN** `LICENSE` includes `MIT`
- **AND** `LICENSE` includes at least one additional Gentoo license token required by a bundled library that is not MIT

### Requirement: Release tarball SRC_URI without overlay-assets

`SRC_URI` SHALL be the GitHub release download  
`https://github.com/fukamachi/qlot/releases/download/${PV}/qlot-${PV}.tar.gz`.  
The ebuild SHALL NOT add an `mndz-overlay-assets` distfile. The ebuild SHALL NOT use the git-tag archive URL (`archive/refs/tags`) as the primary source. `S` SHALL be `${WORKDIR}/qlot` (tarball root directory name `qlot/`).

#### Scenario: SRC_URI is the release asset

- **WHEN** the ebuild is inspected
- **THEN** `SRC_URI` names `qlot-${PV}.tar.gz` under `fukamachi/qlot/releases/download`
- **AND** it does not contain `mndz-overlay-assets`
- **AND** it does not use `archive/refs/tags` as the primary archive

### Requirement: Compile uses bundled libs and SBCL_HOME

`src_compile` SHALL export `SBCL_HOME` to `/usr/$(get_libdir)/sbcl` (or `EPREFIX`-qualified equivalent) in the ebuild environment. It SHALL require `.bundle-libs/setup.lisp` in `${S}` and SHALL run upstream `scripts/setup.sh` (or an equivalent load of that bundle that compiles qlot). Compile SHALL NOT fetch `https://beta.quicklisp.org/quicklisp.lisp` or invoke `ql-dist:install-dist` / `ql:update-all-dists` against a live Quicklisp dist. The ebuild SHALL NOT run upstream `scripts/install.sh`.

#### Scenario: Missing bundle dies

- **WHEN** the unpacked tree has no `.bundle-libs/setup.lisp`
- **THEN** compile dies before treating the package as successfully built

#### Scenario: No live Quicklisp dist install at compile

- **WHEN** compile runs with Portage network isolation for the package
- **THEN** compile does not require `beta.quicklisp.org`

### Requirement: Install layout under /usr/share/qlot

The package SHALL install the qlot project tree (including `bin/qlot`, `scripts/`, `src/`, `qlot.asd`, `quicklisp-client/`, and `.bundle-libs/`) under `/usr/share/qlot`. It SHALL install `/usr/bin/qlot` as a symlink to `/usr/share/qlot/bin/qlot` so `qlot` is on `PATH`. Installed scripts that the trampoline executes SHALL be executable. The package SHALL NOT inherit `common-lisp-3` as the primary layout. The package SHALL NOT symlink `qlot.asd` into `/usr/share/common-lisp/systems`.

#### Scenario: PATH entry after emerge

- **WHEN** the package is emerged
- **THEN** `/usr/bin/qlot` exists and resolves to `/usr/share/qlot/bin/qlot`
- **AND** `/usr/share/qlot/.bundle-libs/setup.lisp` exists

#### Scenario: Not on the global ASDF systems path

- **WHEN** the package is emerged
- **THEN** `/usr/share/common-lisp/systems/qlot.asd` is not installed by this package

### Requirement: Dependencies and Autolith isolation

The ebuild SHALL depend on `dev-lisp/sbcl` without USE `source`, on `dev-libs/openssl:=`, and on `dev-vcs/git` (build and run as applicable). The seed SHALL NOT add `dev-lisp/qlot` to `dev-util/autolith` `DEPEND`, `RDEPEND`, or `BDEPEND`.

#### Scenario: SBCL without source USE

- **WHEN** the ebuild dependency atoms are inspected
- **THEN** the SBCL atom does not enable `[source]`
- **AND** openssl and git are declared

#### Scenario: Autolith ebuild unchanged for qlot

- **WHEN** the seed is complete
- **THEN** `dev-util/autolith` does not list `dev-lisp/qlot` as a dependency

### Requirement: KEYWORDS tilde-only matching SBCL arches

The ebuild SHALL set  
`KEYWORDS="~amd64 ~ppc ~ppc64 ~riscv ~sparc ~x86 ~x64-macos"`  
(order may vary). Every arch token SHALL be tilde-only. The seed SHALL NOT keyword `arm64`. The seed SHALL NOT copy Gentoo `dev-lisp/sbcl`’s `-*` token.

#### Scenario: Keyword set

- **WHEN** the ebuild is inspected
- **THEN** KEYWORDS include `~amd64` and `~ppc64` and `~riscv` and `~x86`
- **AND** KEYWORDS do not include bare `amd64` or `~arm64` or `-*`

### Requirement: test USE gate

The ebuild SHALL include `test` in `IUSE` and set `RESTRICT` to include `!test? ( test )`. `src_test` SHALL run a minimal offline verification (installed or in-tree `qlot --version` / load of the bundled setup) when Portage allows the test phase. The ebuild SHALL NOT inherit `shell-completion` or declare bash/zsh/fish completion USE flags solely for qlot.

#### Scenario: tests restricted when USE=-test

- **WHEN** `USE=-test` and the package is emerged with `FEATURES=test`
- **THEN** the test phase is restricted and does not run package tests

### Requirement: Operator smoke acceptance

After the overlay package is committed with Manifest and package cache, the operator SHALL verify install by emerging `=dev-lisp/qlot-1.8.4` (or the revised `-rN` atom if used) and running `qlot --version` from `PATH`. The command SHALL print a line containing `1.8.4`. Upstream 1.8.4 then calls `uiop:quit -1` (process status 255) after printing; that status is accepted and SHALL NOT be treated as a packaging failure.

#### Scenario: smoke commands

- **WHEN** seed publish is complete
- **THEN** emerge of that atom succeeds
- **AND** `qlot --version` from `PATH` prints a line containing 1.8.4
