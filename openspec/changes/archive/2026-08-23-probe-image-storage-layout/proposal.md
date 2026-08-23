## Why

Before `docker build` of the materialize image, `update` charges a conservative 20 GiB (first image) or 8 GiB (add-toolchain) to `docker info`’s `DockerRootDir`, falling back to `/var/lib/docker`, and the same bound on a distinct overlay bind path. On hosts that use the containerd snapshotter with a **system** containerd, image layers live under containerd’s data root (often a different filesystem) while `DockerRootDir` holds BuildKit cache. That mis-attributes the full layer budget to the wrong volume: an 8 GiB docker LV can never pass a 20 GiB first-image gate even when containerd has tens of GiB free, and a full containerd LV would not be gated at all.

## What Changes

- **Probe storage layout** from live Docker/containerd configuration (`docker info` JSON and, when needed, `containerd config dump`). Do not hardcode `/var/lib/docker` or `/var/lib/containerd`, and do not keep a silent path-literal fallback.
- **Gate by role and filesystem**, reusing same-device merge: image layers vs BuildKit cache. Same device keeps today’s combined 20 GiB / 8 GiB bounds. Distinct devices use split constants (first image 16 GiB layers + 6 GiB cache; add-toolchain 6 GiB layers + 2 GiB cache). Fail if any required volume is short.
- **Stop charging the overlay bind-mount** as image-build storage (it is read-only).
- **Discovery miss is a hard-fail** when the snapshotter is in use, containerd is not docker-bundled, and the data root cannot be resolved. Do not talk to the containerd gRPC socket (root-only on typical setups). Do not guess a default root.
- **Operator-visible error** names probed paths, roles (image layers vs build cache), and free vs need. When the two roles are on distinct devices, list both even if only one is short. Discovery miss is a separate message (not a free-space line).
- **README** documents that the image-build gate uses probed Docker/containerd storage, not a hardcoded docker data directory.

**Not BREAKING** for overlay consumers. **Operator-visible:** insufficient-image-disk errors may name two paths and roles; some hosts that false-failed on `DockerRootDir` will pass; snapshotter hosts with an unresolvable containerd root will fail closed instead of building.

### Non-goals

- Modeling BuildKit cache hit-rate; automatic `docker builder prune` or `docker image prune -a`
- Privileged access to the containerd socket, `/proc` of the daemon, or systemd `ExecStart` parsing for a non-default `--config`
- Remote `buildx` builders, Docker Desktop VMs, Podman
- Changing needs-work unit temp/distfiles feasibility, first-image vs add-toolchain classification, or the generated Dockerfile
- Retuning split constants from a live materialize build (operator will grow a tight cache LV if needed; constants may be revisited after successful runs)

## Capabilities

### New Capabilities

<!-- none — layout probe is part of the existing image-build disk gate -->

### Modified Capabilities

- `ensure-materialize-image`: Conservative free-space-before-`docker build` uses probed Docker/containerd storage roles (layers vs cache), same-device combined bounds vs split bounds, no overlay-bind charge, discovery hard-fail when snapshotter layers cannot be located
- `disk-space-preflight`: Same image-build gate: evaluate the filesystems that actually back image layers and BuildKit cache; do not require overlay-path space for a read-only bind
- `project-docs`: README describes probed image-build storage (docker data-root and, when distinct, containerd image store), role-aware insufficient-space messages, and that a hardcoded `/var/lib/docker` is not the check

## Impact

- **Code:** `Update.Materialize.Ensure` (`imageDiskGate`, `discoverDockerRoot`); small pure parse of `docker info` JSON / containerd dump (`root`, non-empty snapshotter `root_path`); injectable `CommandRunner` already used for `docker info`
- **Tests:** Fake `docker info` JSON (classic graph driver vs `io.containerd.snapshotter.v1` + system vs bundled socket); fake `containerd config dump`; assert which path is charged which bound; discovery miss does not `docker build`; overlay distinct device is not gated; no live daemon in `hk check`
- **Docs:** `README.md` free-space / materialize ensure (project-docs)
- **Operator:** Error text; shanty-style split LVs gated correctly; `containerd` CLI needed only for the system-snapshotter discovery branch
