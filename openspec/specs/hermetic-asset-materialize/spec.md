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

When at least one classified unit is full path and will mutate, preflight SHALL require `docker` on `PATH`. A usable product materialize image SHALL be provided by `ensure-materialize-image` (build or reuse) unless `MNDZ_MATERIALIZE_IMAGE` names an override tag, in which case that tag MUST already be usable. Missing Docker, a failed ensure, or an unusable override image SHALL log an error and fail those full-path units (or exit with status `1` before their mutation) as specified by `ensure-materialize-image` and `update-command`. The program SHALL NOT fall back to host `go`, `npm`, `bun`, `sbcl`, `pycargoebuild`, or other host language toolchains for that full-path work. The program SHALL NOT require the operator to run `docker build` as a prerequisite of `update` when the default product tag is used.

#### Scenario: No docker hard-fails before mutate

- **WHEN** `update` will full-path materialize at least one unit and `docker` is not on `PATH`
- **THEN** the program exits with status `1` before overlay or assets mutation of those units and does not run host `go`/`npm`/`bun` instead

#### Scenario: Reuse-only update does not require docker

- **WHEN** every DepsAndAssets unit that needs work is classified reuse
- **THEN** preflight does not fail solely because `docker` is missing

#### Scenario: Missing default image is ensured not a recipe-only fail

- **WHEN** `update` will full-path materialize at least one unit, `docker` is on `PATH`, the default product tag is missing, and `MNDZ_MATERIALIZE_IMAGE` is unset
- **THEN** the program ensures the image (generate and `docker build`) rather than only printing a manual `docker build` command as the hard-fail

### Requirement: One container session per full-path unit

When `update` full-path materializes a DepsAndAssets unit, the program SHALL use **one** Docker container session for that unit’s language work (clone, ecosystem toolchain, pack to unit `out/`). The session SHALL be created and started before those commands, each language/`git`/`tar`/`pycargoebuild` (and equivalent) invocation SHALL run as `docker exec` into that session (not a new `docker run` per command), and the session SHALL be removed when that unit’s materialize ends (success or hard-fail). Sequential PVs of the same package SHALL use sequential sessions (a new session per unit). Concurrent package jobs under `--jobs` MAY have one live session each. Reuse-path units SHALL NOT start a materialize session. PID 1 in the session MAY be a long-sleep (or equivalent) so exec can attach; the program SHALL NOT use a restart policy that brings the container back after remove.

The session SHALL be named so an operator can identify it while it runs (name containing a product prefix, the run id, category, package, and PV, with `/` replaced so the name is a legal Docker name). The session SHALL carry product labels including a run id and the host CLI process id so leftovers can be swept. After start, the program SHALL wait until the session is running before the first exec, or hard-fail that unit. If session create/start fails, that unit SHALL hard-fail. If an exec fails because the session is not running, that unit SHALL hard-fail; the program SHALL NOT silently open a replacement session for that unit.

At the start of a mutate that will full-path materialize, the program SHALL best-effort remove leftover product-labeled materialize sessions whose recorded CLI pid is not a live overlay-manager process. Sweep SHALL NOT hard-fail the run. Sweep SHALL NOT remove sessions labeled with a still-live overlay-manager pid (another concurrent run). At unit end the program SHALL `docker rm -f` that session (and `--rm` MAY also be set on create). Failed units keep the host unit directory as specified by `temp-workspace`; the program SHALL NOT keep the container after the unit ends solely for debugging.

#### Scenario: Cargo extract uses one session

- **WHEN** full-path materialize runs for a Cargo unit whose lock lists many registry crates
- **THEN** the program starts one materialize container for that unit
- **AND** crate extract `tar` invocations run as `docker exec` into that container
- **AND** the container is removed when that unit’s materialize ends

#### Scenario: Sequential PVs get sequential sessions

- **WHEN** a package job full-path materializes two PVs in order
- **THEN** the second PV does not reuse the first PV’s container
- **AND** at most one of those two sessions is live at a time for that package job

#### Scenario: Session create failure hard-fails the unit

- **WHEN** full-path materialize cannot create or start the unit session
- **THEN** that unit hard-fails
- **AND** the program does not fall back to host language toolchains

#### Scenario: Exec into a dead session hard-fails the unit

- **WHEN** a language command is issued and the unit session is not running
- **THEN** that unit hard-fails
- **AND** the program does not start a new session for the same unit to retry that command

#### Scenario: Named session is visible while the unit runs

- **WHEN** a full-path unit session is running for category `dev-util`, package `mise`, PV `2026.8.12`
- **THEN** `docker ps` lists a container whose name includes `mndz-mat-`, the run id, `dev-util`, `mise`, and `2026.8.12`

#### Scenario: Leftover session from a dead CLI is swept

- **WHEN** mutate starts and a product-labeled materialize container exists whose labeled CLI pid is not a live overlay-manager process
- **THEN** the program removes that container
- **AND** mutate does not hard-fail solely because that leftover existed

#### Scenario: Live concurrent run is not swept

- **WHEN** mutate starts and a product-labeled materialize container exists whose labeled CLI pid is a live overlay-manager process
- **THEN** the program does not remove that container as a leftover

### Requirement: Container identity and bind-mount ownership

The materialize container SHALL use a generic home directory `HOME=/home/builder` (or an equivalent non-operator path that is not the host user’s home). Language tools inside the container SHALL NOT read the operator’s `~/.npmrc`, `~/quicklisp`, or other host-home config unless those paths are explicitly bind-mounted (they SHALL NOT be). Unit `work/` and `out/` SHALL be bind-mounted at the **same absolute paths** the host allocated. Files the container writes under those mounts SHALL be owned by the operator’s numeric uid and gid (`docker` `--user` matching the host user on the **session**, not by a fixed image uid such as 1000). Forced session environment (`HOME`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`) SHALL be set when the session is created so every exec inherits it. Per-command working directory and extra environment from the language builder SHALL be passed on that exec. Host secrets (`GITHUB_TOKEN`, GPG, SSH agent) SHALL NOT be passed into the session, as already required by host-keeps-publish.

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

When packing an Sbcl/Autolith `.qlot/` tree, the packed `.qlot/qlot.conf` and `.qlot/source-registry.conf` SHALL NOT contain any `/home/` pathname (operator home, generic builder home, or otherwise). Quicklisp/qlot SHALL run with `HOME` set to the container generic home or the unit work directory, not the operator home. After `qlot install`, the program SHALL drop `:qlot-source-directory`, `:setup-file`, and a source-registry `:directory` entry that names a builder qlot checkout, keeping `:also-exclude` entries. The program SHALL NOT rewrite those keys to `/home/builder` or another home. If a packed conf still contains `/home/` after that step, pack SHALL hard-fail that unit.

#### Scenario: qlot.conf has no operator home

- **WHEN** full-path Autolith materialize packs `{pn}-{pv}-deps.tar.xz`
- **THEN** `.qlot/qlot.conf` and `.qlot/source-registry.conf` do not contain `/home/`

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

### Requirement: Container does not inherit host SBCL_HOME

When full-path materialize runs a language command in the materialize container, the program SHALL NOT pass the host process environment variables `SBCL_HOME` or `SBCL_SOURCE_ROOT` into the container. SBCL inside the container SHALL use the image-configured `SBCL_HOME` when SBCL is present. The program SHALL NOT bind-mount the operator’s `~/quicklisp` to satisfy this.

#### Scenario: Host SBCL_HOME is not forwarded

- **WHEN** full-path materialize execs a command in the unit session and the host environment has `SBCL_HOME` set
- **THEN** the session and that exec do not include `SBCL_HOME` from the host
- **AND** they do not include host `SBCL_SOURCE_ROOT`

### Requirement: Full-path Sbcl materialize uses image qlot CLI

When full-path materialize for `DepsAndAssets Sbcl` runs qlot inside the materialize container, it SHALL invoke `qlot` from the image `PATH` (`qlot install` in the cloned project) with `HOME` the generic builder home. It SHALL NOT load `/home/builder/quicklisp/setup.lisp`, SHALL NOT load Autolith `script/qlot-install.lisp` as the primary path, and SHALL NOT bind-mount the operator `~/quicklisp`. Packed `.qlot` configs SHALL still be rewritten so they contain no `/home/` pathnames as already specified by `sbcl-deps-assets`.

#### Scenario: Container qlot install does not use Quicklisp setup.lisp

- **WHEN** full-path Autolith materialize runs qlot in the container
- **THEN** the language command is `qlot` (install) on the image `PATH`
- **AND** the invocation does not `--load` `/home/builder/quicklisp/setup.lisp`
