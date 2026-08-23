## ADDED Requirements

### Requirement: Conservative free space before materialize image build

When `update` will `docker build` a materialize image as specified by `ensure-materialize-image`, the program SHALL evaluate free space on the filesystem that backs Docker image storage (and the overlay path when it will be bind-mounted into that build) and SHALL hard-fail that ensure before starting `docker build` if free bytes are below a conservative bound for the layers about to run. The bound MAY distinguish a first full image from adding one toolchain. The program SHALL NOT require a precise model of Docker layer or BuildKit cache reuse. When ensure will not `docker build`, this check SHALL NOT fail the run solely for image-build space. This gate is in addition to the existing needs-work unit gate for materialize `work/`/`out/` and manager distfiles.

#### Scenario: No build skips image-build space fail

- **WHEN** the current materialize image already satisfies this prepare
- **THEN** `update` does not hard-fail solely because Docker storage would be insufficient for a full rebuild

#### Scenario: First image build gated

- **WHEN** ensure will `docker build` a first materialize image and Docker storage free space is below the conservative bound
- **THEN** ensure hard-fails before `docker build` with a message that names the path and free versus need
