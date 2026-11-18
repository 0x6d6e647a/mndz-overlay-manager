# Spec Delta

## MODIFIED Requirements

### Requirement: Conservative free space before smoke image build

When `smoke`, or `update` for its gated runs, will `docker build` the smoke image as specified by `smoke-image`, the program SHALL evaluate free space on the filesystems that back image layers and BuildKit cache, discovered the same way as for a materialize image build. When free bytes are below a conservative bound for a base-only image, `smoke` SHALL exit with status `1` before `docker build`, and `update` SHALL act as specified by `update-smoke-gate` for unready gate prerequisites. When the smoke image will not be built, this check SHALL NOT fail the command.

#### Scenario: Build gated

- **WHEN** `smoke` will build its image and the filesystem that backs image layers is below the bound
- **THEN** the command exits with status `1` before `docker build`, naming the probed path and free versus need

#### Scenario: Reused image skips the gate

- **WHEN** the recorded smoke image is reused
- **THEN** `smoke` does not fail solely because Docker storage would be too small for a rebuild

#### Scenario: Update needs a smoke image build on a full disk

- **WHEN** `update` needs the smoke image, it must be built, and the image-layer filesystem is below the bound
- **THEN** no unit is published or committed and `update` exits with status `1` naming the probed path and free versus need

### Requirement: Smoke does not estimate per-run build space

`smoke` and `update` SHALL NOT estimate or reserve free space for the tree snapshot or for builds inside smoke containers. The `update` disk-space feasibility gate SHALL NOT include gated runs. A standalone smoke run that exhausts storage SHALL be reported as a failed run with its log, and the command SHALL continue with the next run. A gated run that exhausts storage SHALL fail its gate as specified by `update-smoke-gate`.

#### Scenario: Build runs out of space

- **WHEN** the package step of a run fails because the container's storage is full
- **THEN** that run is reported as `fail: build` and the next run starts

#### Scenario: Gated run runs out of space

- **WHEN** a gated run's package step fails because container storage is full
- **THEN** that unit's gate fails and other units continue
