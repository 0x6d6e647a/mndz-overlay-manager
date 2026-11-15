# Spec Delta

## MODIFIED Requirements

### Requirement: README documents gencache and md5-cache tools

`README.md` SHALL document the `gencache` work subcommand (purpose, optional package targets, `--force`, and at least one example), SHALL state that `update` and `gencache` run `egencache` in a container (so they require `docker`, not host `egencache`), and SHALL briefly describe the operator bootstrap/recovery sequence: ensure `cache-formats = md5-dict` in overlay `layout.conf`, run `gencache` for initial cache, use `update` for version bumps, and use `gencache` / `gencache --force` when `update` reports missing or mismatched md5-cache.

#### Scenario: README catalogs gencache

- **WHEN** an operator reads `README.md`
- **THEN** the document describes `gencache` with an example invocation
- **AND** runtime requirements list `docker` for `update` and `gencache` and do not list host `egencache` or `ebuild`

### Requirement: README documents update free-space behavior and TMPDIR

When the product performs free-space feasibility checks for `update`, `README.md` SHALL document at operator depth:

1. That `update` checks free space on the effective temp root (`TMPDIR` or system default) and the manager distfiles path before heavy concurrent mutation.
2. That free-space estimates cover only packages that **need work** and heavy units, using prior Manifest/GitHub asset sizes with **reuse vs full-path** classification, ecosystem factors for full path, and a fixed safety margin—not a full-path estimate for every inventory package on bare `update`.
3. That `update` plans which packages need work (using the check cache when enabled) before the free-space gate and conditional assets/language tool requirements that depend on needs-work.
4. Remediation: free space, set `TMPDIR` to roomier storage (for example under `$HOME`), and lower `--jobs`.
5. That mid-materialize ENOSPC is a failure mode the gate is intended to prevent when free space is already insufficient for the planned concurrent work.
6. That heavy product temporary work is nested under `$TMPDIR/mndz/overlay-manager/<run-id>/` (or the process default temp root when `TMPDIR` is unset), with per-unit trees; successful units are cleaned immediately; hard-fail retains the failing unit tree and names its path in the error; a fully successful run removes the run root and empty parent brand directories; residuals after crashes or hard-fails may be removed manually by the operator.
7. That when `update` will `docker build` the materialize image, it also checks free space on the Docker data-root (BuildKit cache) and, when Docker stores image layers in containerd on a distinct filesystem, that containerd data-root; that those directories are discovered from Docker/containerd configuration rather than a hardcoded `/var/lib/docker`; that insufficient space names the probed path(s), role (image layers versus build cache), and free versus need; and that the overlay tree bind-mounted into the build is not part of that image-storage check.

#### Scenario: Operator finds TMPDIR guidance in README

- **WHEN** an operator reads `README.md` after this capability ships
- **THEN** the documentation describes `TMPDIR`, free-space remediation, needs-work-scoped estimates, and the product temporary workspace layout and retention behavior for `update` without requiring OpenSpec as the primary path

#### Scenario: README mentions plan before free-space gate

- **WHEN** an operator reads the `update` free-space documentation
- **THEN** the text indicates that free-space checks apply to packages that need work after planning, not every package in the overlay inventory

#### Scenario: Operator finds image-build storage probe in README

- **WHEN** an operator reads the `update` free-space or materialize image documentation
- **THEN** the text states that a materialize `docker build` is gated on probed Docker/containerd storage
- **AND** it does not describe `/var/lib/docker` as the only image-storage path

### Requirement: README documents Docker full-path materialize and config mode

`README.md` SHALL document at operator depth:

1. That `update` of DepsAndAssets packages that need **full-path** materialize requires `docker` on `PATH` and a product Gentoo materialize image (host CPU architecture), and does not require host `go` / `npm` / `bun` / `sbcl` / `pycargoebuild` for that path.
2. That reuse of existing assets releases does not require Docker or those language tools.
3. That GPG-signed commits, SSH `git push`, GitHub token, and overlay/assets worktrees stay on the host, while `ebuild … manifest` and `egencache` run in a container from the materialize image family.
4. That `update` **ensures** the default materialize image when full-path work needs it (generate and `docker build` if the current image does not satisfy those floors); that GitMv/reuse may proceed while ensure runs; that Bun in the image comes from overlay `dev-lang/bun-bin::mndz`; that qlot in the image (when SBCL is installed) comes from overlay `dev-lisp/qlot::mndz` rather than a live Quicklisp installer fetch; that `node-gyp` in the image (when bun or node is installed) comes from overlay `dev-build/node-gyp::mndz`; that metadata lives under the XDG cache `…/mndz/overlay-manager/materialize/` (`image.json`); that `MNDZ_MATERIALIZE_IMAGE` uses an existing tag and is not built or deleted by the CLI; that a manual `docker build` of an in-repo Dockerfile is **not** a required prerequisite of `update`; that the git tree SHALL NOT ship `docker/materialize/` (recipe or pointer) as operator documentation; that ensure’s generated recipe uses an official Gentoo `stage3` glibc OpenRC flavor for the host CPU architecture, pinned by digest and rechecked for a newer digest every `materialize-base-check-interval`; and that a host architecture with no such official flavor hard-fails ensure (no host language-toolchain fallback).
5. That work commands hard-fail when the overlay-manager TOML is not exactly mode `0600` or its mode cannot be read, without changing token resolution.
6. That the generated image installs language toolchains via Portage: prefers a Gentoo `-bin` package when one can meet the floor, accepts testing KEYWORDS per atom (`~arch`, `::gentoo` or `::mndz`) when the floor is not stable-visible, does not set whole-image `ACCEPT_KEYWORDS` to `~arch`, and reuses local binpkgs across image rebuilds.
7. That image Portage DISTDIR, PKGDIR, and binhost fetch caches live in Docker BuildKit (not under XDG `…/mndz/overlay-manager/` except `image.json` / the last Dockerfile); that a successful default-tag `docker build` runs `eclean-pkg --deep` and `eclean-dist --deep` after toolchain install so those caches keep exact installed versions; that `docker builder prune` wipes them (ensure does not run it); that sizes appear in the ensure build log; and that moving a warm cache to another machine means copying `image.json` together with the docker image, not copying a host directory of binpkgs.

#### Scenario: Operator finds Docker in the runtime table

- **WHEN** an operator reads `README.md` runtime requirements
- **THEN** the documentation lists `docker` for full-path `update` of vendor/deps/crates packages and does not claim host `go`/`npm`/`bun` are required for that path
- **AND** the image tool list names overlay qlot (not a wget of Quicklisp) when describing SBCL/Autolith materialize tools
- **AND** the image tool list names overlay `node-gyp` when describing Bun or npm materialize tools

#### Scenario: Operator finds config mode warning

- **WHEN** an operator reads `README.md` configuration documentation
- **THEN** the documentation states that a config file not mode `0600` is a hard failure

#### Scenario: Operator finds auto-ensure not a manual docker build recipe

- **WHEN** an operator reads `README.md` materialize image documentation
- **THEN** the text describes `update` ensuring the image for full-path work
- **AND** it does not present a manual `docker build -f docker/materialize/Dockerfile` as the required setup step before `update`

#### Scenario: Operator does not find an in-repo materialize recipe directory

- **WHEN** an operator inspects the repository for a materialize Docker recipe
- **THEN** there is no `docker/materialize/` directory (Dockerfile or pointer README)
- **AND** `README.md` is the operator documentation for image ensure

#### Scenario: Operator finds OpenRC stage3 and unsupported-arch hard-fail

- **WHEN** an operator reads `README.md` materialize image documentation
- **THEN** the text states that ensure uses an official Gentoo OpenRC stage3 for the host CPU architecture
- **AND** that a host architecture without such an image hard-fails (host `go`/`npm`/`bun` are not used instead)

#### Scenario: Operator finds Portage -bin and per-atom testing keywords

- **WHEN** an operator reads `README.md` materialize image documentation
- **THEN** the text states that toolchains come from Portage `-bin` when available
- **AND** that testing toolchain versions are accepted per package, not by setting the whole image to `~arch`
- **AND** that image rebuilds reuse locally built binpkgs

#### Scenario: Operator finds BuildKit Portage caches and prune

- **WHEN** an operator reads `README.md` materialize image documentation
- **THEN** the text states that DISTDIR, PKGDIR, and binhost caches live in Docker BuildKit, not as XDG binpkg trees
- **AND** that a successful image build prunes those caches to installed versions with Gentoo `eclean --deep`
- **AND** that `docker builder prune` wipes them
- **AND** that a cache-only copy is not a migrate path (copy `image.json` and the docker image, or accept a cold compile)

## ADDED Requirements

### Requirement: README documents the managed Gentoo tree

`README.md` SHALL document that the program keeps its own Gentoo tree under the XDG cache (`…/mndz/overlay-manager/gentoo`) instead of reading the host's, that it comes from the Gentoo git mirror verified with host `gpg` against the Gentoo repository-mirror key, and that a sync targets the newest mirror commit the binhost has caught up with.

#### Scenario: Operator finds the managed tree

- **WHEN** an operator reads `README.md` cache documentation
- **THEN** it names the managed tree path and its git and gpg verification
- **AND** it states that the host's Gentoo tree and Portage tools are not used

### Requirement: README documents tree and base freshness settings

`README.md` SHALL document config keys `gentoo-tree-max-age` (default `6h`) and `materialize-base-check-interval` (default `3d`), that `--refresh` also syncs the tree, which commands sync, and that an existing tree is kept with a warning when the mirror or binhost is unreachable.

#### Scenario: Operator finds the freshness keys

- **WHEN** an operator reads `README.md` configuration documentation
- **THEN** it lists both keys with their defaults and the offline behavior

### Requirement: README runtime table matches host requirements

`README.md` runtime requirements SHALL state: `list` needs neither Portage, GPG, nor Docker; `outdated` needs `git` and `gpg` (for the tree) but not Portage or Docker; `update` and `gencache` need `git`, `gpg`, and `docker` but not host `ebuild`, `egencache`, or `portageq`; and the first `update` or `gencache` on a host with no image builds a base-only image.

#### Scenario: Operator reads outdated requirements

- **WHEN** an operator reads the README runtime requirements for `outdated`
- **THEN** it lists `git` and `gpg` and does not list Portage or Docker
