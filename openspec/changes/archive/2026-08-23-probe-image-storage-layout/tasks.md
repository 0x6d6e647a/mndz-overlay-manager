## 1. Layout parse (pure)

- [x] 1.1 Parse `docker info` JSON: `DockerRootDir`, snapshotter (`DriverStatus` `driver-type` = `io.containerd.snapshotter.v1`), `Containerd.Address`; bundled vs system from the address
- [x] 1.2 Parse `containerd config dump` text: top-level `root`; non-empty snapshotter plugin `root_path`
- [x] 1.3 Pure layout: classic / bundled snapshotter → cache+layers under Docker data-root; system snapshotter → layers at containerd root, cache at Docker data-root; missing `DockerRootDir` or missing containerd root when required is discovery error
- [x] 1.4 Role bounds: combined 20 GiB / 8 GiB same device; first-image 16 GiB layers + 6 GiB cache; add-toolchain 6 GiB layers + 2 GiB cache; export alongside existing first/add constants
- [x] 1.5 Tests: JSON fixtures (overlay2, snapshotter+system socket, snapshotter+bundled socket); dump with `root` and with non-empty `root_path`; dump miss / empty root is Left

## 2. Image disk gate

- [x] 2.1 Replace `discoverDockerRoot` path-literal fallback: `docker info --format '{{json .}}'`; on system snapshotter run `containerd config dump` (no `--config`); do not contact the containerd socket
- [x] 2.2 `imageDiskGate` uses layout + `DiskSpaceProbe` device-id merge; overlay path is not a volume; include `DockerRootDir/buildkit` when that directory exists
- [x] 2.3 Insufficient-space message: one path+combined need when same device; both paths, roles, and free vs need when distinct; discovery miss is a separate message (image store unresolved)
- [x] 2.4 Wire ensure: skip gate when no build; discovery or space fail is `Left` before `docker build`

## 3. Ensure tests (fakes only)

- [x] 3.1 Extend `FakeDocker` `docker info` to JSON; optional `containerd config dump`; keep inspect/build stubs
- [x] 3.2 Combined tiny store: first build fails, names Docker data-root, no `docker build`
- [x] 3.3 Split: cache short / layers ample → fail, lists both roles; layers short / cache ample → fail, lists both roles
- [x] 3.4 Split both ample → `docker build` runs; overlay on a distinct tiny device does not fail
- [x] 3.5 System snapshotter with dump missing or root path missing → discovery fail, no `docker build`; bundled snapshotter does not invoke dump
- [x] 3.6 Satisfies still skips the disk gate (existing case, still green)

## 4. Docs and quality gate

- [x] 4.1 `README.md`: image-build free-space uses probed Docker data-root and, when distinct, containerd image store; error names path and role; overlay bind is not that check; do not document `/var/lib/docker` as the only store (`project-docs`)
- [x] 4.2 `openspec validate --strict` for this change (and affected capabilities) clean
- [x] 4.3 `hk check` green; no weeder/stan weakening; no `exposed-modules` expansion unless the test-suite requires it; internals stay `other-modules`
