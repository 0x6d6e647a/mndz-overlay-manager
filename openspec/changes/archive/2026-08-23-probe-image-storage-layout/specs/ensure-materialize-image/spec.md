## MODIFIED Requirements

### Requirement: Conservative free space before docker build

When ensure will `docker build`, the program SHALL hard-fail before starting that build if free space on the filesystems that back **image layers** and **BuildKit cache** is below a conservative bound for the work that build will run. The program SHALL discover those directories from live Docker and, when needed, containerd configuration (Docker data-root and, when the containerd snapshotter holds image layers, containerd’s data root including a non-empty snapshotter `root_path`). The program SHALL NOT treat a hardcoded docker data directory as the image store, SHALL NOT fall back to a path literal when discovery fails, and SHALL NOT charge the overlay bind-mount used as a read-only build context. Paths that share a filesystem SHALL use one **combined** bound (first full image versus adding one toolchain). Distinct filesystems SHALL use **role** bounds (layers versus cache) for that same first-image versus add-toolchain distinction; the program SHALL hard-fail if **either** distinct volume is short. The program SHALL NOT attempt to subtract BuildKit cache hit-rate. When `image.json` already satisfies and no build will run, this check SHALL NOT fail the run solely for image-build space.

When Docker’s storage driver is the containerd snapshotter and containerd is not the engine-bundled instance (layers are not under the Docker data-root), and the program cannot resolve containerd’s data root from configuration, ensure SHALL hard-fail before `docker build` with a message that the image store could not be resolved. That message SHALL NOT be a free-space line. The program SHALL NOT contact the containerd gRPC socket for this gate.

When the gate fails for insufficient space and layer and cache paths are on distinct filesystems, the error SHALL name both probed paths, their roles (image layers versus build cache), and free versus need for each. When they share a filesystem, the error SHALL name that path and the combined free versus need.

#### Scenario: Satisfies skips image disk gate

- **WHEN** the current image already satisfies this prepare
- **THEN** `update` does not hard-fail solely because Docker storage would be tight for a hypothetical full rebuild

#### Scenario: First build fails early on tiny disk

- **WHEN** there is no image, this prepare needs a full-path image, Docker keeps image layers and BuildKit cache on one filesystem, and that filesystem’s free space is below the combined first-image bound
- **THEN** ensure hard-fails before `docker build`
- **AND** the error names that storage path and free versus need

#### Scenario: Split store fails on the cache filesystem

- **WHEN** ensure will `docker build` a first materialize image, image layers and BuildKit cache are on distinct filesystems, the layer filesystem has at least the first-image layer bound free, and the cache filesystem is below the first-image cache bound
- **THEN** ensure hard-fails before `docker build`
- **AND** the error names both paths and roles

#### Scenario: Split store fails on the layer filesystem

- **WHEN** ensure will `docker build` a first materialize image, image layers and BuildKit cache are on distinct filesystems, the cache filesystem has at least the first-image cache bound free, and the layer filesystem is below the first-image layer bound
- **THEN** ensure hard-fails before `docker build`
- **AND** the error names both paths and roles

#### Scenario: Overlay bind is not an image-storage volume

- **WHEN** ensure will `docker build`, Docker/containerd storage filesystems have enough free space, and the overlay tree is on a distinct filesystem with very little free space
- **THEN** ensure does not hard-fail solely because the overlay path is tight

#### Scenario: Unresolved snapshotter image store fails closed

- **WHEN** ensure will `docker build`, Docker uses the containerd snapshotter with a containerd instance that does not keep image layers under the Docker data-root, and containerd’s data root cannot be resolved from configuration
- **THEN** ensure hard-fails before `docker build`
- **AND** the error states that the image store could not be resolved
- **AND** the program does not `docker build`
