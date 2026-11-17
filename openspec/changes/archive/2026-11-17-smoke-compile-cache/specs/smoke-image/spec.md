# Spec Delta

## MODIFIED Requirements

### Requirement: Smoke image contents are minimal

The generated recipe SHALL start from the official `gentoo/stage3` glibc OpenRC flavor for the host architecture, pinned by digest. It SHALL upgrade Portage, run `emerge --update --deep --newuse @world`, and install `sys-process/time` and `dev-util/ccache`. It SHALL NOT install language toolchains, fetch tools, version-control tools, or any overlay package.

#### Scenario: No toolchains

- **WHEN** the smoke image is built
- **THEN** a container from it has no `go`, `node`, `bun`, `cargo`, or `sbcl` on `PATH`

#### Scenario: GNU time is present

- **WHEN** the smoke image is built
- **THEN** `/usr/bin/time --version` in a container from it identifies GNU Time

#### Scenario: ccache is present

- **WHEN** the smoke image is built
- **THEN** `ccache --version` succeeds in a container from it

## ADDED Requirements

### Requirement: Smoke image build keeps built binary packages

Each recipe `RUN` that invokes Portage SHALL build binary packages for what it compiles and SHALL install from them when they match, using a binary-package build cache mount used only by the smoke image build. A package that has no binary on the Gentoo binhost SHALL therefore be compiled at most once while that build cache survives.

#### Scenario: Rebuild after a stage3 change

- **WHEN** the smoke image was built once, compiling a package the binhost lacks, and is built again from a new stage3 digest
- **THEN** the second build installs that package from the build cache instead of compiling it

#### Scenario: Cache identity is smoke-only

- **WHEN** the generated smoke recipe is inspected
- **THEN** its binary-package cache mount identity does not appear in the materialize recipe
