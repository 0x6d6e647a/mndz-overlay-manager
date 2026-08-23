## MODIFIED Requirements

### Requirement: Conservative free space before materialize image build

When `update` will `docker build` a materialize image as specified by `ensure-materialize-image`, the program SHALL evaluate free space on the filesystems that back **image layers** and **BuildKit cache**, discovered from live Docker and (when needed) containerd configuration, and SHALL hard-fail that ensure before starting `docker build` if free bytes are below a conservative bound for the work about to run. Paths that share a filesystem SHALL use one combined bound; distinct filesystems SHALL use role bounds (layers versus cache). The bound MAY distinguish a first full image from adding one toolchain. The program SHALL NOT charge the overlay path used as a read-only bind-mount. The program SHALL NOT require a precise model of Docker layer or BuildKit cache reuse. The program SHALL NOT treat a hardcoded docker data directory as the sole image-storage filesystem. When Docker uses the containerd snapshotter and image layers are not under the Docker data-root, and containerd’s data root cannot be resolved, this gate SHALL hard-fail before `docker build` as specified by `ensure-materialize-image`. When ensure will not `docker build`, this check SHALL NOT fail the run solely for image-build space. This gate is in addition to the existing needs-work unit gate for materialize `work/`/`out/` and manager distfiles.

#### Scenario: No build skips image-build space fail

- **WHEN** the current materialize image already satisfies this prepare
- **THEN** `update` does not hard-fail solely because Docker storage would be insufficient for a full rebuild

#### Scenario: First image build gated

- **WHEN** ensure will `docker build` a first materialize image and the filesystem that backs image layers (and, when distinct, BuildKit cache) is below the conservative bound for that role
- **THEN** ensure hard-fails before `docker build` with a message that names the probed path(s) and free versus need

#### Scenario: Distinct cache and layer volumes are both listed

- **WHEN** ensure will `docker build`, image layers and BuildKit cache are on distinct filesystems, and at least one of those filesystems is below its role bound
- **THEN** the error names both paths, their roles, and free versus need for each
