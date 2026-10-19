# uv-deps-assets Specification

## Purpose

Uv `DepsAndAssets` packs a committed `uv.lock` into one offline deps tarball and records the real Git tag on each source archive URL.

## Requirements

### Requirement: Uv ecosystem under DepsAndAssets

The program SHALL support `DepsAndAssets` with ecosystem `Uv`. Policy SHALL carry an optional lock subdirectory relative to the repository root; unset means `uv.lock` at the root. Apply SHALL dispatch Uv materialization, the frozen-sync slot probe, the Python slot atom, and `dev-lang/python` runtime lanes for this ecosystem.

#### Scenario: Root lock uses the Uv path

- **WHEN** policy uses `DepsAndAssets` with ecosystem `Uv` and no lock subdirectory
- **THEN** planning reads `uv.lock` at the repository root and uses Python runtime lanes

### Requirement: Missing uv.lock hard-fails

When `uv.lock` is absent at the policy path for a `DepsAndAssets Uv` package, planning SHALL hard-fail that package. The program SHALL NOT create or refresh a lock by running `uv lock`.

#### Scenario: Absent lock fails planning

- **WHEN** a candidate tag has no `uv.lock` at the policy path
- **THEN** planning fails for that package and does not write a lock file

### Requirement: Parser accepts uv.lock documents

The parser SHALL accept a `uv.lock` document at version 1, revisions 2 and 3, including registry distributions, file hashes, environment markers, dependency groups, and git or path dependencies. A document the parser cannot read SHALL hard-fail the package.

#### Scenario: Revisions 2 and 3

- **WHEN** a lock is version 1 at revision 2 or revision 3 and uses package entries
- **THEN** the parser accepts the document

#### Scenario: Git or path dependency

- **WHEN** a package entry is a git dependency or a path dependency
- **THEN** the parser accepts that entry

### Requirement: Parser accepts Windows-only lock entries

The parser SHALL accept a lock entry whose dependency edges are gated only by Windows markers. Acceptance SHALL NOT require that entry to be packed.

#### Scenario: Windows-only entry stays in the lock model

- **WHEN** a distribution is required only under a Windows platform marker
- **THEN** parsing succeeds and packing is not required to include that distribution

### Requirement: Linux closure omits Windows-only distributions

The packer SHALL pack distributions required for a Linux install of the runtime dependencies and the dev dependency groups at the chosen Python slot. It SHALL omit a distribution whose incoming edges are all Windows platform markers. It SHALL keep a distribution that also has an unconditional or non-Windows edge.

#### Scenario: Windows-only distribution omitted

- **WHEN** a distribution is required only by a Windows platform marker
- **THEN** the deps tarball does not contain that distribution

#### Scenario: Shared distribution packed

- **WHEN** a distribution is required both unconditionally and by a Windows marker
- **THEN** the deps tarball contains that distribution

### Requirement: Sdists and cargo vendor trees

The deps tarball SHALL contain source distributions for the packed closure and SHALL NOT contain manylinux wheels for those distributions. When a packed Rust source distribution has no `vendor/` directory, the tarball SHALL include a `cargo vendor` tree for that distribution.

#### Scenario: Unvendored Rust sdist

- **WHEN** a packed Rust source distribution ships without a `vendor/` directory
- **THEN** the deps tarball includes a cargo vendor tree for it

### Requirement: Build-backend sdists

The deps tarball SHALL contain a source distribution for every PEP 517 `build-system.requires` entry of a packed distribution, resolved at the chosen Python slot. Each distinct requirement list SHALL be resolved on its own. A packed distribution with no `[build-system]` table SHALL contribute `setuptools` and `wheel`. The tarball SHALL NOT contain wheels for those backends. The ebuild SHALL leave build isolation on and SHALL NOT depend on those backends as Gentoo packages.

#### Scenario: Backend closure is packed

- **WHEN** a packed distribution declares `build-system.requires`
- **THEN** the deps tarball contains an sdist for each distribution that requirement list resolves to
- **AND** the ebuild does not name that backend as a Gentoo dependency
- **AND** the install does not pass `--no-build-isolation`

#### Scenario: Missing build-system table

- **WHEN** a packed distribution has no `[build-system]` table
- **THEN** the deps tarball contains sdists for `setuptools` and `wheel`

### Requirement: Backend planner files stay in the unit work directory

When the materialize container resolves a build-system requirement list, the program SHALL create the requirements file, the dry-run venv, and the PyPI sdist-url script under that unit's work directory. The program SHALL NOT give the container a path that exists only on the host.

#### Scenario: Dry-run files are on the work mount

- **WHEN** the container dry-runs a build-system requirement list
- **THEN** the requirements file and the venv are under the unit work directory

#### Scenario: PyPI lookup script is on the work mount

- **WHEN** the container looks up a backend sdist URL
- **THEN** the helper script is under the unit work directory

### Requirement: Frozen sync does not author a lock

Packing SHALL use a frozen install that refuses to update `uv.lock`. That install SHALL pass `--python` the slot runtime-lanes chose for that PV and SHALL set `UV_PYTHON_DOWNLOADS=never`. A lock whose recorded project version differs from `pyproject.toml` SHALL still pack when that frozen install succeeds. The program SHALL NOT run `uv lock` to repair it.

#### Scenario: Stale lock still packs

- **WHEN** frozen sync succeeds and `uv lock --check` would report that the lock needs an update
- **THEN** packing succeeds and the committed `uv.lock` is left unchanged

### Requirement: Uv distfile name

For package name PN and version PV without revision, the program SHALL name the Uv distfile `{pn}-{pv}-deps.tar.xz` and the assets release `{pn}-{pv}`. Names SHALL use the overlay package name.

#### Scenario: codex-as-mcp deps name

- **WHEN** publishing assets for package `codex-as-mcp` at PV `2026.2.2.1`
- **THEN** the distfile basename is `codex-as-mcp-2026.2.2.1-deps.tar.xz` and the release tag is `codex-as-mcp-2026.2.2.1`

### Requirement: Source archive records the real tag

When rewriting a Uv ebuild, the upstream source archive URL SHALL use `archive/refs/tags/<tag>.tar.gz`, where `<tag>` is the git tag that parsed to that PV. The assets deps URL SHALL stay parameterized with `${PV}`. The program SHALL NOT replace `<tag>` with a `v${PV}` or `${PV}` spelling that is not that tag.

#### Scenario: Unprefixed tag

- **WHEN** the tag that parsed to PV `2026.2.2.1` is `2026.2.2.1`
- **THEN** the archive URL contains `refs/tags/2026.2.2.1.tar.gz`
- **AND** the assets deps URL contains `codex-as-mcp-${PV}`

#### Scenario: Prefixed tag

- **WHEN** the tag that parsed to PV `2026.6.29.1` is `v2026.6.29.1`
- **THEN** the archive URL contains `refs/tags/v2026.6.29.1.tar.gz`

### Requirement: Rewrite sets the Python slot atom

When rewriting a Uv ebuild, the program SHALL set the Python dependency to `dev-lang/python:<slot>` and `PYTHON_COMPAT` to that slot alone, where `<slot>` is the slot runtime-lanes chose for that PV. The program SHALL rewrite each `/usr/bin/python<major>.<minor>` interpreter path to `/usr/bin/python<slot>`. Donor `IUSE` and `src_test` SHALL be preserved. The remainder of `src_install` SHALL be preserved. A free-threaded token such as `python3_13t` SHALL stay.

#### Scenario: Slot atom follows the chosen slot

- **WHEN** apply writes a Uv PV whose chosen slot is `3.14`
- **THEN** the ebuild depends on `dev-lang/python:3.14`
- **AND** `PYTHON_COMPAT` names `python3_14` only
- **AND** donor `IUSE` and `src_test` remain

#### Scenario: Venv interpreter follows the chosen slot

- **WHEN** apply writes a Uv PV whose chosen slot is `3.13` and the donor creates the venv with `/usr/bin/python3.14`
- **THEN** the ebuild depends on `dev-lang/python:3.13`
- **AND** `PYTHON_COMPAT` names `python3_13` only
- **AND** the venv interpreter path is `/usr/bin/python3.13`
- **AND** donor `IUSE` and `src_test` remain

### Requirement: Offline emerge of the packed closure

The published deps tarball SHALL be sufficient for the ebuild to install the locked closure with no network access. The emerge that consumes the tarball SHALL NOT fetch distribution files from the network.

#### Scenario: Emerge does not fetch distributions

- **WHEN** the ebuild installs a Uv package from the deps tarball
- **THEN** the install does not contact a package index or a source forge for those distributions
