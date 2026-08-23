## Context

See `proposal.md` for motivation. `imageDiskGate` in `Update.Materialize.Ensure` calls `discoverDockerRoot`: `docker info --format '{{.DockerRootDir}}'`, else `"/var/lib/docker"`. It `statvfs`s that path against `firstImageNeedBytes` (20 GiB) or `addToolchainNeedBytes` (8 GiB), then the overlay root at the **same** bound when `dspDeviceId` differs. Overlay bind in the generated recipe is `--mount=type=bind,...,ro`. `DiskSpaceProbe` and same-device merge already exist for temp vs manager distfiles; the image gate does not use that merge. `FakeDocker` stubs `docker info` as the literal `/var/lib/docker\n`. aeson is already a dependency (`image.json`). No live `docker build` in `hk check`.

On a host with `features.containerd-snapshotter` and system containerd (`Containerd.Address` = `/run/containerd/containerd.sock`), `DriverStatus` includes `driver-type=io.containerd.snapshotter.v1`. Image layers live under containerd `root`; BuildKit cache stays under `DockerRootDir`. `containerd config dump` (no `--config`; default file is `/etc/containerd/config.toml`) emits top-level `root` and plugin `root_path` (empty means the default under `root`). Dump does not use the gRPC socket.

## Goals / Non-Goals

**Goals:**

- Replace path-literal Docker-root discovery with a layout probe (`docker info` JSON, `containerd config dump` when snapshotter layers are not under Docker data-root).
- Apply combined vs role bounds after device-id merge; drop overlay from this gate.
- Keep tests on injectable `CommandRunner` / `DiskSpaceProbe`; no live daemon.

**Non-Goals:**

- BuildKit occupancy accounting; socket/`ctr`/gRPC; systemd `ExecStart` or `/proc` cmdline for a non-default containerd `--config`; remote builders; changing Dockerfile or unit temp/distfiles gates.

## Decisions

### D1: Parse `docker info` JSON, not the Go template string

**Choice:** `docker info --format '{{json .}}'`. Take `DockerRootDir`, `DriverStatus` (snapshotter iff a pair is `driver-type` / `io.containerd.snapshotter.v1`), and `Containerd.Address`. Empty or failed `docker info` is a hard-fail (cannot build anyway). No `"/var/lib/docker"` fallback.

**Why:** One round-trip already used for the root; JSON is what distinguishes snapshotter vs classic graph driver and bundled vs system containerd.

**Alternatives:** Keep `--format '{{.DockerRootDir}}'` and guess containerd — rejected (this bug). Parse `/etc/docker/daemon.json` — rejected (`data-root` is already in `DockerRootDir`).

### D2: Bundled vs system containerd from the socket address

**Choice:** Snapshotter **off** → layer and cache paths are `DockerRootDir` (and `DockerRootDir/buildkit` if that directory exists; merge by device). Snapshotter **on** and `Containerd.Address` is under docker’s runtime dir (`…/docker/containerd/…`) → same, no dump. Snapshotter **on** and address is not bundled → run `containerd config dump`, parse top-level `root = '…'` / `"…"`, then any snapshotter plugin `root_path` that is non-empty; layer path is that root (or `root_path`); cache path remains `DockerRootDir`. If dump fails, is unparsable, or the resolved root path does not exist → discovery hard-fail (not a free-space line).

**Why:** Bundled containerd keeps data under `DockerRootDir`; dumping system `containerd` would point at the wrong tree. System snapshotter is the split-LV case. Empty plugin `root_path` means the default under `root`.

**Alternatives:** Always dump — rejected (wrong root for bundled). Hardcode `/var/lib/containerd` — rejected. `ctr` / socket — rejected (root-only on typical hosts). `--config /etc/containerd/config.toml` — same as the binary default; fails if the file is missing while a bare dump still emits compiled defaults.

### D3: Role bounds and same-device merge

**Choice:** Constants (GiB):

| | Combined (one device) | Layers | Cache |
|---|---|---|---|
| First image | 20 | 16 | 6 |
| Add toolchain | 8 | 6 | 2 |

Same device: **combined** column only (do not sum 16+6). Distinct devices: each role’s column independently; fail if either is short. Optionally `statvfs` `DockerRootDir/buildkit` when it exists; device merge collapses it. Overlay is not a volume in this gate.

**Why:** Combined 20/8 is today’s overlay2 gate. Split cannot share slack; layers (stage3, webrsync, emerge, snapshots) dominate; cache mounts are DISTDIR/PKGDIR. Overlay is read-only.

**Alternatives:** 20 GiB on every distinct device — rejected (false-fails an 8 GiB cache LV). Shrink combined 20 for overlay2 — rejected.

### D4: Error text

**Choice:** Distinct devices: always list both roles with path, free, need (even if only one is short). Same device: one path, combined need. Discovery miss: name that the image store could not be resolved; hint that `containerd config dump` must yield a `root` (do not suggest `ctr` or sudo).

**Why:** A single `/var/lib/docker` line is what made the mis-attribution look like “docker is full.”

### D5: Pure layout + existing probe

**Choice:** Pure function: parsed `docker info` + optional dump text → `{ layerPaths, cachePaths }` or discovery error. IO: `CommandRunner` + `DiskSpaceProbe` as today. New internals as `other-modules` (parser may live next to Ensure; do not expand `exposed-modules`). Tests extend `FakeDocker` to JSON `docker info` and optional `containerd config dump`; no live engine.

**Why:** Same injectable pattern as the rest of ensure. Byte constants stay in Ensure (or the small layout module) like `firstImageNeedBytes`.

**Alternatives:** New weeder roots — rejected. Production `statvfs` of well-known path literals “if they exist” — rejected.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| `containerd` not on PATH on a system-snapshotter host | Discovery hard-fail with dump-oriented message; bundled snapshotter does not need the binary |
| Daemon started with a non-default `--config` | Bare dump is wrong; fail closed rather than guess; no `/proc` or unit parsing in this change |
| 6 GiB cache bound vs an 8 GiB docker LV after PKGDIR grows | Gate fails on the cache volume (correct LV); operator grows or prunes BuildKit; retune constants after measured builds |
| `docker info` JSON field rename | Parse leniently; missing `DockerRootDir` is discovery fail |
| Rootless Docker | `DockerRootDir` already user-local; dump must follow `Containerd.Address` (bundled skip still applies) |

## Migration Plan

No overlay or sidecar format change. Deploy is a CLI rebuild. Rollback is revert; the old gate (20 GiB on `DockerRootDir` plus overlay) returns. No data migration.

## Open Questions

None. Split constants may be retuned after successful live builds without changing the probe/role approach.
