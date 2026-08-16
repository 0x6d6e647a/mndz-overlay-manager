# hermetic-asset-materialize Specification

## Purpose

Full-path DepsAndAssets materialize runs in a host-architecture Gentoo Docker image with a generic home and operator-owned bind-mounts, while reuse, GitHub publish, GPG, SSH, and Portage Manifest stay on the host. Shared pack rules strip builder identity from published tarballs.

## Requirements

### Requirement: Full-path materialize runs in Docker

When `update` classifies a DepsAndAssets unit as **full path**, the program SHALL perform that unit’s language materialize (clone, ecosystem toolchain, pack to unit `out/`) inside a Docker container using a product Gentoo materialize image on the **host CPU architecture**. The Haskell CLI process, overlay and assets git worktrees, GPG signing, SSH, GitHub release upload, and `ebuild … manifest` / `egencache` SHALL remain on the host. The reuse path SHALL NOT start a container solely to download or verify an existing release asset.

#### Scenario: Full-path Go uses the container

- **WHEN** `update` classifies a Go unit as full path
- **THEN** `go mod download` and vendor pack run inside the materialize container and the host CLI receives the tarball under the unit `out/` directory

#### Scenario: Reuse does not start Docker

- **WHEN** `update` classifies a unit as reuse because the assets release already has every required basename
- **THEN** the program downloads the asset on the host and does not start a materialize container for that unit

### Requirement: Docker is mandatory for full path

When at least one classified unit is full path, preflight SHALL require `docker` on `PATH` and a usable product materialize image. Missing Docker or an unusable image SHALL log an error and exit with status `1` before package mutation. The program SHALL NOT fall back to host `go`, `npm`, `bun`, `sbcl`, `pycargoebuild`, or other host language toolchains for that full-path work.

#### Scenario: No docker hard-fails before mutate

- **WHEN** `update` will full-path materialize at least one unit and `docker` is not on `PATH`
- **THEN** the program exits with status `1` before overlay or assets mutation and does not run host `go`/`npm`/`bun` instead

#### Scenario: Reuse-only update does not require docker

- **WHEN** every DepsAndAssets unit that needs work is classified reuse
- **THEN** preflight does not fail solely because `docker` is missing

### Requirement: Container identity and bind-mount ownership

The materialize container SHALL use a generic home directory `HOME=/home/builder` (or an equivalent non-operator path that is not the host user’s home). Language tools inside the container SHALL NOT read the operator’s `~/.npmrc`, `~/quicklisp`, or other host-home config unless those paths are explicitly bind-mounted (they SHALL NOT be). Unit `work/` and `out/` SHALL be bind-mounted at the **same absolute paths** the host allocated. Files the container writes under those mounts SHALL be owned by the operator’s numeric uid and gid (`docker run --user` matching the host user), not by a fixed image uid such as 1000.

#### Scenario: Operator home is not visible

- **WHEN** full-path npm materialize runs
- **THEN** `npm` inside the container does not load `/home/<operator>/.npmrc`

#### Scenario: Output owned by operator

- **WHEN** the container writes `{pn}-{pv}-vendor.tar.xz` under the unit `out/`
- **THEN** that file is owned by the same uid/gid as the host CLI process

### Requirement: Host keeps publish and Manifest

After a successful full-path container materialize, the host CLI SHALL hash sidecars, create the GPG-signed assets commit, `git push` the assets worktree, upload the GitHub release, then rewrite the overlay ebuild and run `ebuild … manifest` and md5-cache as already specified by `assets-publish` and the ecosystem capabilities. The container SHALL NOT receive the GitHub token, GPG agent, or SSH agent solely to perform those steps.

#### Scenario: Token stays on the host

- **WHEN** full-path materialize finishes and assets publish begins
- **THEN** release create/upload runs in the host CLI using the host-resolved token

### Requirement: Hermetic tar and xz

When packing any DepsAndAssets `*.tar.xz` distfile, the program SHALL invoke `tar` so that:

1. Archive members use owner `0`, group `0`, and numeric owner/group (no operator `uname`/`gname`).
2. Member names are sorted (`--sort=name` or equivalent).
3. Member mtimes are clamped to a fixed epoch (`--mtime` / `--clamp-mtime` or equivalent).
4. PAX atime/ctime extended headers are not stored when the tar implementation supports suppressing them.
5. Compression uses `XZ_OPT=-T1 -9e` (extreme xz, **single** thread) or equivalent single-thread extreme settings, and the archive is forced to xz (`-J` or equivalent).
6. The final file is verified to be an xz stream as already required by ecosystem pack rules.

The program SHALL NOT record the operator username or uid in ustar `uname`/`gname`/`uid`/`gid` fields.

#### Scenario: Headers are root numeric

- **WHEN** a Go vendor, npm/Bun deps, cargo crates, or Sbcl deps tarball is packed
- **THEN** `tar --numeric-owner -t` lists members as `0/0` (or equivalent root/root) and not the operator username

#### Scenario: XZ is single-thread extreme

- **WHEN** the manager packs any of those tarballs
- **THEN** the pack process uses `XZ_OPT` containing `-T1` and `-9e` (or equivalent single-thread extreme settings)

### Requirement: Npm cache omits builder logs

When packing an npm `npm-cache/` deps tarball, the archive SHALL include the cache content needed for offline `npm --cache` install and SHALL NOT include `npm-cache/_logs/` or `npm-cache/_update-notifier*` files. Npm SHALL be invoked with an empty userconfig that is not the operator’s `~/.npmrc`.

#### Scenario: Packed cache has no debug log

- **WHEN** full-path npm materialize packs `openspec-{pv}-deps.tar.xz`
- **THEN** the tarball has no member under `npm-cache/_logs/`

### Requirement: Qlot trees have no operator home paths

When packing an Sbcl/Autolith `.qlot/` tree, the packed files SHALL NOT contain the operator’s home directory path (for example `/home/<operator>/quicklisp`). Quicklisp/qlot SHALL run with `HOME` set to the container generic home or the unit work directory, not the operator home. If a generated conf still contains an absolute builder-home pathname, the program SHALL rewrite it to a path that is valid relative to the packed tree or the generic home **before** pack, or hard-fail that unit.

#### Scenario: qlot.conf has no operator home

- **WHEN** full-path Autolith materialize packs `{pn}-{pv}-deps.tar.xz`
- **THEN** `.qlot/qlot.conf` and `.qlot/source-registry.conf` do not contain `/home/<operator>/`

### Requirement: BunCache alias symlinks are relative

When packing a BunCache `bun-cache/` tree, the program SHALL rewrite every symbolic link whose target is an absolute path so the target is a relative path to a member that exists in the same `bun-cache/` tree (for example `bun-cache/gifwrap/0.10.1@@@1` → `../gifwrap@0.10.1@@@1`). If any absolute symlink remains after rewrite, or a rewritten target is missing from the tree, pack SHALL hard-fail before publish.

#### Scenario: Alias links are relative after pack

- **WHEN** full-path BunCache materialize packs `ralph-tui-{pv}-deps.tar.xz`
- **THEN** every symlink member in `bun-cache/` has a relative target and that target exists in the archive

#### Scenario: Absolute leftover hard-fails

- **WHEN** a bun-cache symlink still points at an absolute path after the rewrite step
- **THEN** materialize hard-fails without publishing that tarball

### Requirement: Image toolchain gates

Go / Node / Bun version gates that currently compare a **host** toolchain to an upstream engines/`go.mod` requirement SHALL, on the full path, compare the toolchain **inside the materialize image**. If the image toolchain is too old, that PV SHALL hard-fail without publish. The program SHALL NOT set `GOTOOLCHAIN=auto` to bypass a Go mismatch. Reuse SHALL NOT apply these gates.

#### Scenario: Image Go older than go.mod

- **WHEN** the cloned `go.mod` requires Go `1.26.5` and the materialize image `go version` is older
- **THEN** the unit hard-fails without `go mod download` and the error names both versions
