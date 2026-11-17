# Spec Delta

## ADDED Requirements

### Requirement: Conservative free space before smoke image build

When `smoke` will `docker build` its image as specified by `smoke-image`, the program SHALL evaluate free space on the filesystems that back image layers and BuildKit cache, discovered the same way as for a materialize image build, and SHALL exit with status `1` before `docker build` when free bytes are below a conservative bound for a base-only image. When `smoke` will not build, this check SHALL NOT fail the command.

#### Scenario: Build gated

- **WHEN** `smoke` will build its image and the filesystem that backs image layers is below the bound
- **THEN** the command exits with status `1` before `docker build`, naming the probed path and free versus need

#### Scenario: Reused image skips the gate

- **WHEN** the recorded smoke image is reused
- **THEN** `smoke` does not fail solely because Docker storage would be too small for a rebuild

### Requirement: Smoke does not estimate per-run build space

`smoke` SHALL NOT estimate or reserve free space for the tree snapshot or for builds inside its containers. A run that exhausts storage SHALL be reported as a failed run with its log, and the command SHALL continue with the next run.

#### Scenario: Build runs out of space

- **WHEN** the package step of a run fails because the container's storage is full
- **THEN** that run is reported as `fail: build` and the next run starts
