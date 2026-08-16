## Context

See proposal.md for motivation. Today `Update.Pack.XzTar` runs `tar -cJf` with `XZ_OPT=-T0 -9e` and inherits the process environment. Ecosystem builders (`Update.Go.Vendor`, `Update.Npm.Cache`, `Update.Bun.Cache`, `Update.Cargo.Crates`, `Update.Sbcl.Deps`) exec host PATH tools. `update` preflight requires those tools after reuse/full classify. Publish, GPG, SSH, and `ebuild … manifest` already run **after** `materializeDistfiles` returns paths (`Update.Apply.Materialize.fullDepsPublishAndOverlay`). That split is the seam.

Published audits (2026-08-15) showed `mndz/mndz` tar headers on every ecosystem, npm `_logs` naming `/home/mndz/.npmrc` and the host kernel, Autolith `.qlot` absolute Quicklisp paths, and 220 absolute BunCache alias links. Go vendor and Cargo crate *contents* were otherwise clean.

## Goals / Non-Goals

**Goals:**

- One in-repo Gentoo materialize image; host-arch `docker run` for full-path language work only
- Same absolute unit `work/`/`out/` inside the container as the host disk gate measured
- Hermetic pack in the shared helper so host-only tests and the container produce identity-poor tarballs
- Preflight: `docker` + image for any full-path unit; drop host language-tool requirements for that path
- Config mode `0600` warning on work-command load

**Non-Goals:**

- Design-level: do not invent a new CLI for image build beyond documenting `docker build`
- Do not put GPG/SSH/token into the container
- Do not specify qemu platforms or a second “test” image (later `FROM` this one)
- Do not add `--force-full-assets` (wiki handoff after archive for ralph 0.12.0)

## Decisions

### 1. Wrap production command runner, not rewrite builders

**Choice:** Keep ecosystem `*Ops` and `Update.Process.CommandRunner`. For a full-path unit, the production runner prefixes language/`tar`/`git clone`/`pycargoebuild` invocations with `docker run --rm` … so builder bodies stay unit-tested with fakes.

**Alternatives:** Move each builder’s body into a shell script in the image (duplicates logic); run the entire Haskell CLI in Docker (rejected: GPG/SSH/Portage stay on host).

**Container argv (sketch):**

```text
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/home/builder \
  --env XDG_CONFIG_HOME=/home/builder/.config \
  --env XDG_CACHE_HOME=/tmp/builder-cache \
  --mount type=bind,src=<unit>,dst=<unit> \
  --workdir <cwd> \
  <image> <cmd> <args>
```

`HOME=/home/builder` must exist and be writable by the operator uid (image `USER` plus a world-writable or uid-mapped home, or a tmpfs mount at `/home/builder`). Do **not** bind-mount the operator `$HOME`.

Network: default (clones, registries, crates.io). No `--network=host` required.

### 2. One Gentoo image, pinned in-repo

**Choice:** `docker/materialize/Dockerfile` (or equivalent) based on a Gentoo stage3 or official `gentoo/stage3` plus the tool set: `git`, `tar`, `xz`, `go`, `nodejs`/`npm`, `bun-bin` or equivalent, `sbcl`, Quicklisp+qlot bootstrap **inside the image**, `cargo`, `pycargoebuild` + Portage Python + `aria2c` (and `wget`). Document `docker build -t mndz-overlay-manager/materialize:local …` in README. Image tag used by the CLI is a product constant or env override (`MNDZ_MATERIALIZE_IMAGE`) defaulting to that name.

**Alternatives:** Debian-slim + cargo on the host (rejected: operator chose one Gentoo image); host-toolchain fallback (rejected).

Rebuild cadence: operator rebuilds when engines/`go.mod` exceed the image; image-too-old is a per-PV hard-fail, not a silent `GOTOOLCHAIN=auto`.

### 3. Hermetic pack stays in Haskell

**Choice:** Change `Update.Pack.XzTar.runTarXz` once. All ecosystems inherit owners, sort, mtime clamp (`--mtime=@0 --clamp-mtime` or `SOURCE_DATE_EPOCH=0` plus `--mtime`), `--pax-option=delete=atime,delete=ctime` when GNU tar, `XZ_OPT=-T1 -9e`. Tests assert numeric `0/0` on a tiny fixture archive.

**Why `-T1` not `-T0`:** bit-stable archives across core counts. Compression is still `-9e`.

**Why flags even inside Docker:** container `uname` would still be `builder`/uid-mapped without `--owner=0`. Flags are the published contract.

### 4. Ecosystem filters are pre-pack, still in Haskell

| Ecosystem | Extra step before `packTarXz` |
|-----------|-------------------------------|
| npm | `npm` `--userconfig` empty file under unit `work/`; pack only `npm-cache/` after deleting `_logs/` and `_update-notifier*` |
| BunCache | Walk `bun-cache/`, rewrite absolute symlinks with `posix` relative targets to the `@` form that exists in-tree; hard-fail if any absolute remains |
| InstallTree (opencode) | Shared hermetic tar only (no bun-cache alias rewrite). Node-gyp `config.gypi` home paths should not appear when `HOME=/home/builder`; do not require stripping native build junk in this change unless tests show operator-home strings |
| Sbcl | Set `HOME` to unit work or `/home/builder`; after qlot, scan `.qlot/qlot.conf` and `source-registry.conf` and rewrite/hard-fail if they contain the operator home (container generic home is acceptable if it is not the operator path) |
| Go / Cargo | Shared tar flags only |

### 5. Preflight

After classify:

- Any full-path unit → `findExecutable "docker"` + `docker image inspect <tag>` (or `docker run --rm <tag> true`). Fail naming the missing piece.
- Do **not** require host `go`/`npm`/`bun`/`xz`/`pycargoebuild`/fetchers for full path.
- Reuse-only cargo: drop the current P1 host `pycargoebuild`+fetcher requirement (Haskell already skips pycargo on reuse).
- Remove host cargo wget advisory (image provides `aria2c`).
- Spine still `git`/`ebuild`/`egencache`/`gpg`. Assets still need token + `assets-path` + SSH when publish will run.

### 6. Config 0600 warning

In `Config.Loader.loadConfig` after `doesFileExist`, `getPermissions` / `getFileStatus` and warn via the process logger if mode ≠ `0o600`. Work commands all go through `loadConfig`. Help path unchanged. Tests with a `0644` temp file.

### 7. `--jobs` and Docker

**Choice:** One `docker run` per language command (or per unit if we later batch), concurrent up to `--jobs`. Do not introduce a long-lived sidecar daemon. Disk gate unchanged (same mounts).

### 8. Image presence vs build

The CLI does not `docker build` as a side effect of `update`. Missing image is a preflight hard-fail with a message pointing at README. Operators build the image themselves.

## Risks / Trade-offs

- **[Risk] Image drift vs newest engines.go / bun** → Mitigation: per-PV image toolchain gate; README says rebuild the image; no auto toolchain download.
- **[Risk] `docker run` per `git`/`go`/`tar` is slow** → Mitigation: acceptable for v1; later can batch a unit into one container session without spec change if the observable pack is the same.
- **[Risk] GNU tar `--pax-option` / `--sort=name` missing on exotic tar** → Mitigation: image and Gentoo host both GNU tar; tests use the same helper.
- **[Risk] Operator uid cannot write `/home/builder` in the image** → Mitigation: Dockerfile creates that dir `0777` or we mount a writable tmpfs there in `docker run`.
- **[Risk] Concurrent packages share one image, Docker daemon contention** → Mitigation: existing `--jobs` knob; operators can set `--jobs 1`.
- **[Risk] Bind-mount of `$TMPDIR` paths on unusual Docker rootless setups** → Mitigation: document that the Docker engine must see the same filesystem path; out of scope to support Desktop/VM path translation.
- **[Trade-off] `-T1` is slower than `-T0`** → Accepted for stable bytes.
- **[Trade-off] Go-forward only** → Old GitHub releases keep old headers; ralph 0.12.0 handoff is after archive.

## Migration Plan

1. Land image + hermetic pack + Docker runner + preflight + config warn + README in this change.
2. Operators build the image once, then `update` full-path packages as usual.
3. Existing releases unchanged. After archive, optional wiki handoff republishes `ralph-tui-0.12.0` only.
4. Rollback: revert the change; host toolchains work again. Already-published hermetic tarballs remain valid consumers.

## Open Questions

None that block specs or tasks. Image exact stage3 tag and package list are implementation details for the Dockerfile task.
