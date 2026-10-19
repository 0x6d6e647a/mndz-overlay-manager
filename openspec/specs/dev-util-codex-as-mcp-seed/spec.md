# dev-util-codex-as-mcp-seed Specification

## Purpose

Product truth for `dev-util/codex-as-mcp`: a private uv venv, `external-codex` and `test` USE flags, and the `2026.2.2.1` donor that makes the first update observable.

## Requirements

### Requirement: Package identity and seed version

The seeded package SHALL be `dev-util/codex-as-mcp` at Portage version `2026.2.2.1`, from GitHub `kky42/codex-as-mcp` tag `2026.2.2.1` with no leading `v`. The live ebuild filename SHALL be `codex-as-mcp-2026.2.2.1.ebuild` without a `-r0` suffix. `SLOT` SHALL be `0`. This package SHALL remain distinct from `dev-util/codex` and `dev-util/codex-acp`.

#### Scenario: Seed filename and tag

- **WHEN** the seed package is added to the overlay
- **THEN** the ebuild path is `dev-util/codex-as-mcp/codex-as-mcp-2026.2.2.1.ebuild`
- **AND** the upstream tag checked out for that ebuild is `2026.2.2.1`

### Requirement: Metadata description and license

The ebuild SHALL set `DESCRIPTION` to a short upstream-derived summary, `HOMEPAGE` to `https://github.com/kky42/codex-as-mcp`, and `LICENSE` to `MIT`. `metadata.xml` SHALL declare GitHub remote-id `kky42/codex-as-mcp`.

#### Scenario: License and homepage

- **WHEN** the ebuild and metadata are inspected
- **THEN** `HOMEPAGE` is `https://github.com/kky42/codex-as-mcp`
- **AND** `LICENSE` is `MIT`
- **AND** `metadata.xml` declares remote-id type `github` with value `kky42/codex-as-mcp`

### Requirement: Source archive uses the unprefixed tag

The seed ebuild's primary `SRC_URI` SHALL fetch `https://github.com/kky42/codex-as-mcp/archive/refs/tags/2026.2.2.1.tar.gz` and SHALL rename that distfile onto `${P}.tar.gz`. It SHALL NOT use the tag `v2026.2.2.1`.

#### Scenario: Archive URL spelling

- **WHEN** the seed ebuild is written
- **THEN** `SRC_URI` contains `refs/tags/2026.2.2.1.tar.gz`
- **AND** `SRC_URI` does not contain `refs/tags/v2026.2.2.1.tar.gz`

### Requirement: Deps asset for the seed

A deps tarball named `codex-as-mcp-2026.2.2.1-deps.tar.xz` SHALL be published to `mndz-overlay-assets` as release tag `codex-as-mcp-2026.2.2.1`, with `b3`, `sha256`, and `sha512` checksum sidecars. The ebuild SHALL reference that release with an assets `SRC_URI` parameterized by `${PV}`.

#### Scenario: Assets URL form

- **WHEN** the seed ebuild is written
- **THEN** it contains `https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/codex-as-mcp-${PV}/codex-as-mcp-${PV}-deps.tar.xz`

### Requirement: Seed deps tarball omits Windows-only distributions

The seed deps tarball SHALL NOT contain `pywin32`, `pywin32-ctypes`, or `colorama`. It SHALL include cargo vendor trees for packed Rust source distributions that ship without `vendor/`, including runtime `pydantic-core` and `rpds-py` and dev-group `cryptography` and `nh3` when those distributions are in the Linux closure.

#### Scenario: Windows wheels absent

- **WHEN** the seed deps tarball is unpacked
- **THEN** it contains no `pywin32`, `pywin32-ctypes`, or `colorama` distribution
- **AND** it contains a cargo vendor tree for `pydantic-core` and for `rpds-py`

### Requirement: One Python 3.13 slot

The seed ebuild SHALL depend on `dev-lang/python:3.13` and SHALL set `PYTHON_COMPAT` to `python3_13` only. It SHALL NOT list another Python slot. The venv SHALL be created with `/usr/bin/python3.13`. Build dependencies SHALL include that Python slot, `dev-python/uv`, and `|| ( dev-lang/rust-bin dev-lang/rust )`. OpenSSL and libffi SHALL NOT be runtime `RDEPEND`s.

#### Scenario: Slot and build dependencies

- **WHEN** the seed ebuild is inspected
- **THEN** it depends on `dev-lang/python:3.13` with `PYTHON_COMPAT` naming `python3_13` only
- **AND** it creates the venv with `/usr/bin/python3.13`
- **AND** build dependencies include `dev-python/uv` and `|| ( dev-lang/rust-bin dev-lang/rust )`
- **AND** runtime `RDEPEND` does not name OpenSSL or libffi

### Requirement: Build backends are packed sdists

The seed deps tarball SHALL contain an sdist for every PEP 517 build-system requirement of the packed closure, resolved on Python 3.13, including those backends' own requirements. A packed sdist with no `[build-system]` table SHALL be represented by `setuptools` and `wheel` sdists. The seed ebuild SHALL NOT depend on those backends as Gentoo packages. The install SHALL use build isolation, SHALL NOT set `PYTHONPATH`, and SHALL run the pip install with `PYTHON` unset.

#### Scenario: No Gentoo build backends

- **WHEN** the seed ebuild `BDEPEND` is inspected
- **THEN** it does not depend on `dev-python/hatchling`, `dev-python/uv-dynamic-versioning`, or `dev-util/maturin`
- **AND** the install command does not pass `--no-build-isolation`
- **AND** the install command does not set `PYTHONPATH`
- **AND** the pip install runs with `PYTHON` unset

### Requirement: Private venv and wrapper

The ebuild SHALL install a private virtual environment at `/usr/lib/codex-as-mcp` with system site-packages disabled, and a wrapper at `/usr/bin/codex-as-mcp`. Dev-group distributions SHALL be available to the build and test environment and SHALL NOT be installed into `/usr/lib/codex-as-mcp`.

#### Scenario: Install layout

- **WHEN** the package is installed
- **THEN** `/usr/bin/codex-as-mcp` exists and the private environment is `/usr/lib/codex-as-mcp`
- **AND** that environment does not contain `cryptography`, `cffi`, or `pywin32`

### Requirement: USE flags are external-codex and test

`IUSE` SHALL be `external-codex` and `test`, both default off. The ebuild SHALL NOT declare `bundled-codex` and SHALL NOT set `REQUIRED_USE`. `RESTRICT` SHALL include `!test? ( test )`. `metadata.xml` SHALL describe `external-codex` as using a Codex executable supplied outside Portage.

#### Scenario: Flag set

- **WHEN** the ebuild `IUSE` and `RESTRICT` are inspected
- **THEN** `IUSE` contains `external-codex` and `test` with no default-on `+` prefix
- **AND** `bundled-codex` is absent
- **AND** `RESTRICT` includes `!test? ( test )`

### Requirement: Default Codex dependency

With `external-codex` off, `RDEPEND` SHALL include unversioned `dev-util/codex` and SHALL NOT pin a minimum Codex version. The wrapper SHALL prepend `/usr/bin` so `/usr/bin/codex` is preferred. When `CODEX_PATH` is already set and its basename is `codex`, the wrapper SHALL prepend that directory instead, and that directory wins.

#### Scenario: Flag off depends on overlay Codex

- **WHEN** the ebuild is installed with `USE=-external-codex`
- **THEN** `RDEPEND` includes `dev-util/codex` with no version operator
- **AND** an unset `CODEX_PATH` makes the wrapper prefer `/usr/bin/codex`

#### Scenario: Preset CODEX_PATH wins

- **WHEN** `external-codex` is off and `CODEX_PATH` is set to a path whose basename is `codex`
- **THEN** the wrapper prepends the directory of `CODEX_PATH`

### Requirement: external-codex leaves Codex to the operator

With `external-codex` on, `RDEPEND` SHALL NOT include `dev-util/codex`. When `CODEX_PATH` is set and its basename is `codex`, the wrapper SHALL prepend that directory. When `CODEX_PATH` is unset, the wrapper SHALL leave `PATH` unchanged.

#### Scenario: Flag on has no Codex dependency

- **WHEN** the ebuild is installed with `USE=external-codex`
- **THEN** `RDEPEND` does not include `dev-util/codex`

#### Scenario: Flag on and unset CODEX_PATH

- **WHEN** `external-codex` is on and `CODEX_PATH` is unset
- **THEN** the wrapper does not prepend a Codex directory

### Requirement: CODEX_PATH basename is codex

When `CODEX_PATH` is set and its basename is not `codex`, the wrapper SHALL fail before launching the server.

#### Scenario: Wrong basename

- **WHEN** `CODEX_PATH` ends with a name other than `codex`
- **THEN** the wrapper exits unsuccessfully and does not start the server

### Requirement: Conditional pytest of test_server.py

`src_test` SHALL run pytest on `tests/test_server.py` only when that file exists. When the file is absent, `src_test` SHALL succeed without invoking pytest. `tests/live_codex_smoke.py` SHALL NOT be collected. That pytest SHALL be the one installed into the test venv from the deps tarball. The ebuild SHALL NOT BDEPEND on Gentoo `dev-python/pytest`.

#### Scenario: Seed has no test_server.py

- **WHEN** the test phase runs for PV `2026.2.2.1`, which has no `tests/test_server.py`
- **THEN** `src_test` succeeds and does not invoke pytest

#### Scenario: Later PV runs that file only

- **WHEN** the test phase runs for a PV whose tree contains `tests/test_server.py` and `tests/live_codex_smoke.py`
- **THEN** pytest runs `tests/test_server.py` and does not collect `live_codex_smoke.py`

### Requirement: Postinst sandbox warning

`pkg_postinst` SHALL warn that the server launches Codex with approvals and the sandbox bypassed.

#### Scenario: Warning after install

- **WHEN** `pkg_postinst` runs
- **THEN** the warning states that Codex is launched with approvals and the sandbox bypassed

### Requirement: KEYWORDS follow the Python 3.13 arch set

The seed ebuild SHALL set `KEYWORDS` to the tilde form of every architecture keyworded on `dev-lang/python` slot `3.13` that a targeting tilde lane includes, with no `-*` token and no bare arch token. It SHALL NOT be `-* ~amd64`.

#### Scenario: Full tilde arch set

- **WHEN** slot `3.13` keywords `alpha`, `amd64`, `arm`, `arm64`, `hppa`, `loong`, `m68k`, `mips`, `ppc`, `ppc64`, `riscv`, `s390`, `sparc`, and `x86`
- **THEN** `KEYWORDS` is `~alpha ~amd64 ~arm ~arm64 ~hppa ~loong ~m68k ~mips ~ppc ~ppc64 ~riscv ~s390 ~sparc ~x86`

### Requirement: Seed smoke is the wrapper

Operator acceptance of the seed emerge SHALL be that `/usr/bin/codex-as-mcp --help` runs. The seed emerge SHALL NOT require pytest. Acceptance of the newer ebuild SHALL include an emerge with `USE=test` and `FEATURES=test` in which pytest runs `tests/test_server.py`.

#### Scenario: Seed help

- **WHEN** the seed package has been emerged
- **THEN** `/usr/bin/codex-as-mcp --help` completes successfully

#### Scenario: Newer ebuild test phase

- **WHEN** the newer ebuild is emerged with `USE=test` and `FEATURES=test`
- **THEN** pytest runs `tests/test_server.py`
