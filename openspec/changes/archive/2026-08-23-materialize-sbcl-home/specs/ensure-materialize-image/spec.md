## ADDED Requirements

### Requirement: Image SBCL locates its core without a login shell

When the generated recipe emerges SBCL to meet a floor, it SHALL set image environment `SBCL_HOME` to `/usr/<libdir>/sbcl` and `SBCL_SOURCE_ROOT` to `/usr/<libdir>/sbcl/src`. `<libdir>` SHALL be `lib64` when the host KEYWORDS token is `amd64`, `arm64`, `ppc64`, `riscv`, or `s390`, and `lib` when the token is `x86` or `arm`. Those environment settings SHALL take effect after the sbcl emerge step and before any recipe step that invokes `sbcl`. The recipe SHALL NOT rely on a login shell or `/etc/profile` to publish `SBCL_HOME`. Image SBCL SHALL still not enable `USE=source`.

#### Scenario: amd64 recipe exports lib64 SBCL_HOME

- **WHEN** the host machine is `x86_64` and the recipe emerges `dev-lisp/sbcl`
- **THEN** the recipe contains `ENV SBCL_HOME=/usr/lib64/sbcl`
- **AND** it contains `ENV SBCL_SOURCE_ROOT=/usr/lib64/sbcl/src`
- **AND** those `ENV` lines appear before the recipe invokes `sbcl`

#### Scenario: x86 recipe exports lib SBCL_HOME

- **WHEN** the host machine is `i686` and the recipe emerges `dev-lisp/sbcl`
- **THEN** the recipe contains `ENV SBCL_HOME=/usr/lib/sbcl`
- **AND** it contains `ENV SBCL_SOURCE_ROOT=/usr/lib/sbcl/src`

#### Scenario: bun-only recipe omits SBCL_HOME

- **WHEN** there is no previous image and this prepare’s full-path units are Bun-only
- **THEN** the generated recipe is not required to set `SBCL_HOME` solely because SBCL is unused

### Requirement: Quicklisp bootstrap fetch uses aria2c

When the generated recipe bootstraps image-local Quicklisp/qlot after emerging SBCL, it SHALL fetch the Quicklisp installer with `aria2c`. That fetch SHALL NOT use `wget`. The recipe MAY still install `wget` in the base layer for other tools.

#### Scenario: SBCL recipe fetches the installer with aria2c

- **WHEN** the recipe emerges SBCL and bootstraps Quicklisp
- **THEN** the installer URL is fetched with `aria2c`
- **AND** that fetch line does not invoke `wget`
