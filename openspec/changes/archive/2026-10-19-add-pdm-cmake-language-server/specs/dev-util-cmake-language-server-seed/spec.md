# Spec Delta

## Purpose

Product truth for `dev-util/cmake-language-server`: a private PDM venv, the `format` USE flag, and the `0.1.10` seed that makes the `0.1.11` bump observable.

## ADDED Requirements

### Requirement: Package identity and seed version

The seeded package SHALL be `dev-util/cmake-language-server` at Portage version `0.1.10`, from GitHub `regen100/cmake-language-server` tag `v0.1.10`. The ebuild filename SHALL be `cmake-language-server-0.1.10.ebuild` without a `-r0` suffix. Package `SLOT` SHALL be `0`.

#### Scenario: Seed filename and tag

- **WHEN** the seed package is added to the overlay
- **THEN** the ebuild path is `dev-util/cmake-language-server/cmake-language-server-0.1.10.ebuild`
- **AND** the upstream tag for that ebuild is `v0.1.10`

### Requirement: Metadata description and license

The ebuild SHALL set `DESCRIPTION` to `CMake LSP Implementation`, `HOMEPAGE` to `https://github.com/regen100/cmake-language-server`, and `LICENSE` to `MIT`. `metadata.xml` SHALL declare GitHub remote-id `regen100/cmake-language-server`.

#### Scenario: License and homepage

- **WHEN** the ebuild and metadata are inspected
- **THEN** `HOMEPAGE` is `https://github.com/regen100/cmake-language-server`
- **AND** `LICENSE` is `MIT`
- **AND** `metadata.xml` declares remote-id type `github` with value `regen100/cmake-language-server`

### Requirement: Source archive uses the prefixed tag

The seed ebuild's primary `SRC_URI` SHALL fetch `https://github.com/regen100/cmake-language-server/archive/refs/tags/v0.1.10.tar.gz` and SHALL rename that distfile onto `${P}.tar.gz`.

#### Scenario: Archive URL spelling

- **WHEN** the seed ebuild is written
- **THEN** `SRC_URI` contains `refs/tags/v0.1.10.tar.gz`

### Requirement: Deps asset for the seed

A deps tarball named `cmake-language-server-0.1.10-deps.tar.xz` SHALL be published to `mndz-overlay-assets` as release tag `cmake-language-server-0.1.10`, with `b3`, `sha256`, and `sha512` checksum sidecars. The ebuild SHALL reference that release with an assets `SRC_URI` parameterized by `${PV}`.

#### Scenario: Assets URL form

- **WHEN** the seed ebuild is written
- **THEN** it contains `https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/cmake-language-server-${PV}/cmake-language-server-${PV}-deps.tar.xz`

### Requirement: Seed closure is the dev sync set

The `0.1.10` deps tarball SHALL contain one pure wheel for each locked distribution that `pdm sync -G dev` installs at slot `3.12`, except `coverage`. It SHALL contain the `coverage` `7.4.4` sdist and no `coverage` wheel. It SHALL contain a `setuptools` artifact and a `pdm-backend` wheel. It SHALL NOT contain a lint-only distribution.

#### Scenario: Coverage is an sdist

- **WHEN** the `0.1.10` deps tarball is listed
- **THEN** it contains the `coverage` `7.4.4` sdist
- **AND** it contains no `coverage` wheel
- **AND** it contains pure wheels for `pygls` `1.3.1`, `lsprotocol` `2023.0.1`, `cattrs` `23.2.3`, `attrs` `23.2.0`, `pytest` `8.1.1`, `pytest-datadir` `1.5.0`, `pytest-cov` `5.0.0`, `cmakelang` `0.6.13`, `six` `1.16.0`, `iniconfig` `2.0.0`, `packaging` `24.0`, and `pluggy` `1.4.0`

#### Scenario: Lint tools are absent

- **WHEN** the `0.1.10` deps tarball is listed
- **THEN** it contains no `mypy`, `black`, `flake8`, or `isort` distribution

### Requirement: Seed uses Python 3.12

The seed ebuild SHALL depend on `dev-lang/python:3.12` and SHALL set `PYTHON_COMPAT` to `python3_12` only. It SHALL NOT depend on `dev-python/pygls` or `dev-python/lsprotocol` from another repository.

#### Scenario: Slot atom

- **WHEN** the seed ebuild is inspected
- **THEN** it depends on `dev-lang/python:3.12`
- **AND** `PYTHON_COMPAT` names `python3_12` only
- **AND** it does not depend on `dev-python/pygls`

### Requirement: Private venv at a fixed path

The install SHALL create the virtualenv at `/usr/lib/cmake-language-server` and SHALL NOT move it afterward. It SHALL point `pdm` at `/usr/bin/python3.12` without asking `pdm` to download CPython. The ebuild SHALL symlink `/usr/bin/cmake-language-server` to the virtualenv console script. `BDEPEND` SHALL include `dev-python/pdm`.

#### Scenario: Version command

- **WHEN** the seed is emerged and `cmake-language-server --version` is run
- **THEN** the output contains `cmake-language-server 0.1.10`

#### Scenario: Venv path is stable

- **WHEN** the seed is emerged
- **THEN** the console script shebang uses `/usr/lib/cmake-language-server`
- **AND** no virtualenv is installed under a path that was later moved

### Requirement: Prod sync installs the project offline

The install SHALL replace the source named `pypi` with a `find_links` directory of the unpacked deps files. `PDM_BUILD_SCM_VERSION` SHALL be `${PV}` for `pdm sync --prod`, and that sync SHALL include the project. The install SHALL NOT contact a package index.

#### Scenario: Prod sync stays local

- **WHEN** the seed is emerged
- **THEN** `pdm sync --prod` installs the project and the locked runtime distributions from the deps directory
- **AND** the install does not contact a package index

### Requirement: Host pdm bytecode writes are predicted

`src_install` and `src_test` SHALL call `addpredict` on the site-packages directory that owns the host `pdm` package before they invoke `pdm`. The sandbox SHALL still deny those writes.

#### Scenario: Venv interpreter bytecode does not fail the merge

- **WHEN** `pdm sync` runs under the Portage sandbox
- **THEN** the ebuild predicts writes under the host `pdm` site-packages
- **AND** a denied `.pyc` write there does not fail the merge

### Requirement: Prod sync targets the image virtualenv

`src_install` SHALL point `pdm use` at the interpreter inside the image virtualenv and SHALL run `pdm sync --prod --no-editable` into that virtualenv. The install SHALL NOT leave the project only in a `${S}/.venv`.

#### Scenario: Console script is in the image virtualenv

- **WHEN** the seed is emerged
- **THEN** `/usr/lib/cmake-language-server/bin/cmake-language-server` exists
- **AND** the installed package does not import from the Portage work directory

### Requirement: Tests sync into the temporary virtualenv

`src_test` SHALL point `pdm use` at the interpreter inside the `${T}` virtualenv before `pdm sync -G dev`.

#### Scenario: Dev sync uses the test virtualenv

- **WHEN** `src_test` runs
- **THEN** the dev sync installs into the virtualenv under `${T}`

### Requirement: format USE flag

`IUSE` SHALL include `+format`. When `format` is enabled, the install SHALL add the locked `cmakelang` `0.6.13` and `six` `1.16.0` artifacts to the runtime virtualenv and SHALL symlink `/usr/bin/cmake-format` to that virtualenv's `cmake-format`. When `format` is disabled, the runtime virtualenv SHALL NOT contain those two distributions and `/usr/bin/cmake-format` SHALL NOT be installed.

#### Scenario: Format default installs the script

- **WHEN** the seed is emerged with default USE
- **THEN** `/usr/bin/cmake-format` exists and runs from the runtime virtualenv

#### Scenario: Format off omits the script

- **WHEN** the seed is emerged with `USE=-format`
- **THEN** `/usr/bin/cmake-format` is not installed
- **AND** the runtime virtualenv does not contain `cmakelang`

### Requirement: CMake is a runtime dependency

The ebuild SHALL `RDEPEND` and `BDEPEND` on `dev-build/cmake`. The language server and `src_test` SHALL be able to execute `cmake`.

#### Scenario: CMake atom

- **WHEN** the seed ebuild is inspected
- **THEN** `RDEPEND` and `BDEPEND` include `dev-build/cmake`

### Requirement: Tests use the dev group

`src_test` SHALL run `pdm sync -G dev` with `PDM_BUILD_SCM_VERSION` set to `${PV}` and SHALL NOT pass `-d`. Before pytest, `cmake_language_server/version.py` SHALL exist in the source tree and SHALL define that PV. `src_test` SHALL put the dev environment's `cmake-format` on `PATH`. The test run SHALL NOT require USE `format`.

#### Scenario: Tests see cmake-format without the flag

- **WHEN** `src_test` runs with `USE=-format`
- **THEN** `cmake-format` is on `PATH` from the dev sync
- **AND** the formatting test is not skipped for a missing `cmake-format`

#### Scenario: Version module is in the source tree

- **WHEN** pytest imports `cmake_language_server`
- **THEN** `cmake_language_server/version.py` in the source tree defines the ebuild PV

### Requirement: Tests skip three CMake 4 failures

Pytest SHALL deselect `test_parse_variables`, `test_parse_modules`, and the `test_completions_triggercharacter` case whose arguments are `find_package(` and `Boost`. The other `test_completions_triggercharacter` cases SHALL run.

#### Scenario: Known failures are deselected

- **WHEN** `src_test` runs
- **THEN** pytest does not run `test_parse_variables` or `test_parse_modules`
- **AND** pytest does not run the `find_package(` / `Boost` trigger-character case
- **AND** pytest does run the `GoogleTest` and `PROJECT_VERSION` trigger-character cases

### Requirement: KEYWORDS follow the Python 3.12 arch set

Planned and seed `KEYWORDS` SHALL be the tilde form of each arch that Python slot `3.12` keywords. They SHALL NOT include a bare arch token or `-*`.

#### Scenario: Tilde keywords

- **WHEN** the seed ebuild is inspected
- **THEN** `KEYWORDS` includes `~amd64` and `~arm64`
- **AND** `KEYWORDS` does not include bare `amd64` or `-*`

### Requirement: Seed makes the next release observable

With only the `0.1.10` ebuild present, comparable upstream tags SHALL include `v0.1.11` as PV `0.1.11`. `outdated` for this package SHALL report `0.1.11` as newer work. Target selection SHALL accept `dev-util/cmake-language-server` and the bare name `cmake-language-server`, and SHALL reject a version pin.

#### Scenario: Outdated sees 0.1.11

- **WHEN** the overlay has only `cmake-language-server-0.1.10.ebuild` and the upstream tags include `v0.1.11`
- **THEN** `outdated` reports PV `0.1.11` for `dev-util/cmake-language-server`

#### Scenario: Version pin is not a target

- **WHEN** the operator passes `cmake-language-server-0.1.11` as a package target
- **THEN** the command rejects that token and does not select a PV from it
