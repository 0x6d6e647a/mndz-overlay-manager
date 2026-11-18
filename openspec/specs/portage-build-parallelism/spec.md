# portage-build-parallelism Specification

## Purpose

Define consistent build parallelism for Portage in manager-built Docker images and manager-started workload containers.

## Requirements

### Requirement: Managed image builds set a processor-based default

Every manager-built image that runs Portage SHALL set `MAKEOPTS="-jN -l(N+1)"` in `/etc/portage/make.conf` before its first Portage operation and retain that setting in the finished image. N SHALL be the processor count reported by `nproc` inside the Docker build environment.

#### Scenario: Smoke or materialize image build

- **WHEN** a managed smoke or materialize image build sees `nproc` report 8
- **THEN** its first and subsequent emerges use `MAKEOPTS="-j8 -l9"`
- **AND** the finished image retains that default for direct launches

### Requirement: Managed Portage workloads use the command jobs count

Before handing control to the workload in any manager-started container that runs Portage, the manager SHALL set `MAKEOPTS="-jN -l(N+1)"` in the container's `/etc/portage/make.conf`, where N is the command's resolved jobs count. The assignment SHALL supersede the inherited value while preserving unrelated configuration. Changing the command's jobs count SHALL NOT by itself require rebuilding the image.

#### Scenario: Reused image gets the current jobs limit

- **WHEN** smoke, a materialize session, or a Portage tools session starts with `--jobs 4` from an image containing `MAKEOPTS="-j8 -l9"`
- **THEN** the workload sees `MAKEOPTS="-j4 -l5"` in `/etc/portage/make.conf`
- **AND** the source image still contains `MAKEOPTS="-j8 -l9"`

#### Scenario: Jobs flag is omitted

- **WHEN** a Portage workload container starts on a 16-processor host and the operator omits `--jobs`
- **THEN** the workload sees `MAKEOPTS="-j16 -l17"`

#### Scenario: Operator-supplied materialize image is used

- **WHEN** the manager starts a Portage workload from a usable `MNDZ_MATERIALIZE_IMAGE` tag
- **THEN** it applies the same runtime override in the container filesystem

### Requirement: Configuration failure stops the workload

If the manager cannot set the required runtime `MAKEOPTS`, it SHALL report a container setup failure and SHALL NOT start that workload.

#### Scenario: Operator image has an unwritable configuration

- **WHEN** a container started from an operator-supplied image cannot update `/etc/portage/make.conf`
- **THEN** setup fails with an error identifying the configuration failure
- **AND** the workload does not run
