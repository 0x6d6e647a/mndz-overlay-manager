## ADDED Requirements

### Requirement: Package identity and version pin

The seeded package SHALL be `dev-util/autolith` at Portage version `0.17.2`, corresponding to upstream GitHub tag `v0.17.2` on `luciusmagn/autolith`. The seed SHALL NOT use a newer upstream tag for the initial ebuild. The live ebuild filename SHALL be `autolith-0.17.2.ebuild` without a `-r0` suffix; content-only fixes before or after first publish SHALL use `-r1` or greater when a revision bump is required.

#### Scenario: Filename and tag

- **WHEN** the seed package is added to the overlay
- **THEN** the ebuild path is `dev-util/autolith/autolith-0.17.2.ebuild` (or `autolith-0.17.2-rN.ebuild` only if a content revision is required)
- **AND** the primary source archive is the GitHub archive for tag `v0.17.2`

### Requirement: Metadata description and license

The ebuild SHALL set `DESCRIPTION` to a short summary synthesizing upstream README and GitHub (live self-modifying Common Lisp AI agent), `HOMEPAGE` to `https://github.com/luciusmagn/autolith`, and `LICENSE="ISC"`. `metadata.xml` SHALL declare GitHub remote-id `luciusmagn/autolith`.

#### Scenario: License and homepage

- **WHEN** the ebuild is inspected
- **THEN** it uses Gentoo license name `ISC` and the GitHub homepage above

### Requirement: Offline deps assets publish

A dependency tarball named `autolith-0.17.2-deps.tar.xz` SHALL be published to mndz-overlay-assets as release tag `autolith-0.17.2` with checksum sidecars under `dev-util/autolith/`. The tarball SHALL contain a top-level `.qlot/` tree produced from the tag’s `qlfile.lock` and a top-level `fff/` tree for the commit pinned in upstream `native/fff/commit`, including Cargo vendor output sufficient for offline `cargo build --offline`. The ebuild SHALL reference the release via a fully parameterized assets `SRC_URI` using `${PV}`.

#### Scenario: Assets URL form

- **WHEN** the ebuild is written
- **THEN** it contains a `SRC_URI` entry of the form  
  `https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/autolith-${PV}/autolith-${PV}-deps.tar.xz`

#### Scenario: Offline fff build inputs

- **WHEN** the deps tarball is unpacked for compile
- **THEN** fff can be built with cargo offline using vendored crates (no crates.io access)

### Requirement: Deps tarball helper script

The mndz-overlay repository SHALL include `autolith-make-deps-tarball.py` at the overlay root (alongside other `*-make-*-tarball.py` helpers) that builds the deps tarball layout for a given Autolith checkout/tag. The script is for developer/seed materialize hosts with network; Portage SHALL NOT invoke it during emerge.

#### Scenario: Helper present

- **WHEN** the seed change is complete in the overlay
- **THEN** `autolith-make-deps-tarball.py` exists at the overlay root and documents usage consistent with other overlay helpers

### Requirement: SBCL floor dependency and identity stamp

The ebuild SHALL depend on `>=dev-lisp/sbcl-2.6.4:=[source]` (build and run). At compile time it SHALL refuse a host SBCL older than the floor from upstream `sbcl.version` at the packaged tag, and SHALL stamp the installed package so Autolith’s expected SBCL version equals the build-time `lisp-implementation-version`. The package SHALL provide a matching SBCL source root for that same version (synthetic root over Gentoo `USE=source` paths, or full source unpack fallback) and export it to the runtime via `AUTOLITH_SBCL_SOURCE_ROOT` (and system SBCL via `AUTOLITH_SBCL`).

#### Scenario: Floor and stamp

- **WHEN** the package is built against Gentoo SBCL 2.6.6 with `USE=source`
- **THEN** the installed Autolith tree expects SBCL 2.6.6 (not the unstamped upstream 2.6.4 pin alone)
- **AND** the runtime can resolve matching SBCL sources for that version

### Requirement: No network SBCL install at runtime

The packaged install SHALL NOT download SBCL binaries or sources from the network during normal `autolith` invocation. Network-oriented installers (`bin/autolith-runtime` download paths, release `script/install`) SHALL be disabled, omitted as entrypoints, or hard-failed with a message directing operators to system SBCL.

#### Scenario: No curl install path

- **WHEN** a user runs the installed `autolith` without a pre-managed Autolith SBCL under XDG
- **THEN** the process uses system SBCL from the dependency and does not attempt to fetch SBCL from SourceForge or similar

### Requirement: Private application layout and wrapper

The package SHALL install Autolith under a private prefix (not the global `common-lisp-3` library registry as the primary layout) and SHALL install a `/usr/bin/autolith` wrapper that sets required environment variables (SBCL, SBCL source root, native library paths, core paths as applicable). Compile SHALL be able to fabricate git provenance in the source tree when recovery/active image builders require it.

#### Scenario: Wrapper entrypoint

- **WHEN** the package is emerged
- **THEN** `/usr/bin/autolith` exists and runs the packaged Autolith for `autolith --version`

### Requirement: Offline native and Lisp compile

`src_compile` (and related phases) SHALL build without network access for Autolith dependencies: load from the deps tarball `.qlot/` tree, build fff with cargo offline from vendored crates, build other private natives as required, and produce recovery and active cores when using emerge-time core packaging (preferred C lean A; pure system-core layout allowed if hybrid is not workable).

#### Scenario: FEATURES network isolation for package deps

- **WHEN** Autolith is compiled with Portage network isolation for the package build
- **THEN** compile does not require fetching qlot or cargo crates from the internet

### Requirement: KEYWORDS and bubblewrap

The ebuild SHALL set  
`KEYWORDS="~amd64 ~ppc ~ppc64 ~riscv ~x86"`  
and SHALL runtime-depend on `sys-apps/bubblewrap` (unconditional for those keywords). The seed SHALL NOT keyword `arm64`, `sparc`, or `x64-macos`.

#### Scenario: Keyword set

- **WHEN** the ebuild is inspected
- **THEN** KEYWORDS are exactly the tilde set above (order may vary)
- **AND** bubblewrap is in RDEPEND

### Requirement: test USE gate

The ebuild SHALL include `test` in `IUSE` and set `RESTRICT` to include `!test? ( test )`. `src_test` SHALL run a minimal offline verification when Portage allows the test phase. The ebuild SHALL NOT inherit `shell-completion` or declare bash/zsh/fish completion USE flags solely for Autolith (upstream provides no shell completion generator).

#### Scenario: tests restricted when USE=-test

- **WHEN** `USE=-test` and the package is emerged with `FEATURES=test`
- **THEN** the test phase is restricted and does not run package tests

#### Scenario: no shell-completion USE

- **WHEN** the ebuild is inspected
- **THEN** it does not declare `bash-completion`, `zsh-completion`, or `fish-completion` USE flags for Autolith shell integration

### Requirement: Operator smoke acceptance

After overlay and assets are published, the operator SHALL verify install by emerging `=dev-util/autolith-0.17.2` (or the revised `-rN` atom if used) and running `autolith --version` successfully.

#### Scenario: smoke commands

- **WHEN** seed publish is complete
- **THEN** emerge of that atom succeeds
- **AND** `autolith --version` exits successfully and reports version 0.17.2
