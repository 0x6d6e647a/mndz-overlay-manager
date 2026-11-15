# Spec Delta

## MODIFIED Requirements

### Requirement: Generated Gentoo image; install order; no official tarballs

The program SHALL generate the Dockerfile (or equivalent build recipe) used by ensure. The image SHALL be Gentoo on the host CPU architecture. The generated `FROM` line SHALL name an official `gentoo/stage3` **glibc OpenRC** flavor tag mapped from the host machine (`uname -m`), pinned by the digest recorded for the image base (`gentoo/stage3:<tag>@sha256:<digest>`), not the Portage KEYWORDS token concatenated onto `gentoo/stage3:`. The program SHALL NOT use Hub tags `amd64` or `arm64` as `FROM`, SHALL NOT use `gentoo/stage3:latest` as the generated `FROM`, and SHALL NOT use systemd, musl, llvm, hardened, or desktop flavor tags for that `FROM`. Portage `package.accept_keywords` SHALL use the Gentoo KEYWORDS token for the host (`amd64`, `arm64`, `ppc64`, `riscv`, `s390`, `x86`, `arm`).

Before `docker build`, the program SHALL choose **one** Portage atom per needed toolchain by scanning the managed Gentoo tree (or overlay, for bun-bin) package directories: if a `-bin` package exists and has a host-arch ebuild whose version is greater than or equal to the floor (plain or tilde KEYWORDS), that `-bin` atom SHALL be used; otherwise the corresponding source package SHALL be used when it likewise has such an ebuild. The generated recipe SHALL `emerge` that single atom (`>=` the floor, or unversioned when the floor token is any-version). The recipe SHALL NOT trial-emerge a missing `-bin` package with a shell `||` fallback. A local binpkg of the chosen atom SHALL be preferred over compiling (`usepkg` / PKGDIR, then `getbinpkg` from the configured binhost, then compile). After a successful merge the build SHALL write a binpkg (`buildpkg`) into the image’s PKGDIR cache mount.

Every recipe `RUN` that invokes Portage (`emerge`, `getuto`, `eclean-pkg`, or `eclean-dist`) SHALL cache-mount all three of:

- `/var/cache/distfiles` with BuildKit cache id `mndz-materialize-distfiles`
- `/var/cache/binpkgs` with BuildKit cache id `mndz-materialize-binpkgs`
- `/var/cache/binhost` with BuildKit cache id `mndz-materialize-binhost`

Those ids SHALL stay stable across generator and recipe-text changes so a later rebuild can reuse the same caches. The program SHALL NOT bind-mount host filesystem paths as those three Portage directories during `docker build`. The program SHALL NOT install Go, Node, Bun, Rust, or SBCL from upstream official tarball/zip URLs as a substitute for Portage. Overlay ebuild KEYWORDS and BDEPEND/RDEPEND SHALL remain as specified by runtime-lanes and ecosystem capabilities; the image is not an overlay package. Image SBCL SHALL NOT enable `USE=source`. The generated image SHALL include `app-portage/gentoolkit` so `eclean-pkg` and `eclean-dist` are available for Portage cache prune as specified below.

When the chosen atom has no host-arch ebuild ≥ the floor with **plain** KEYWORDS, the recipe SHALL write package-level `package.accept_keywords` of the form `>=cat/pkg-VER::repo ~<keywords-token>` (`::gentoo` for tree toolchains, `::mndz` for overlay bun-bin) and SHALL NOT set whole-image `ACCEPT_KEYWORDS` to `~arch`. When a plain-visible ebuild already meets the floor, that line SHALL be omitted for that atom.

When generating a recipe, the program SHALL map host `uname -m` as follows:

| `uname -m` | KEYWORDS token | `FROM gentoo/stage3:` |
|------------|----------------|------------------------|
| `x86_64` | `amd64` | `amd64-openrc` |
| `aarch64` | `arm64` | `arm64-openrc` |
| `ppc64le` | `ppc64` | `ppc64le-openrc` |
| `riscv64` | `riscv` | `rv64_lp64d-openrc` |
| `s390x` | `s390` | `s390x-openrc` |
| `i686` or `i386` | `x86` | `i686-openrc` |
| `armv7l` | `arm` | `armv7a_hardfp-openrc` |
| `armv6l` | `arm` | `armv6j_hardfp-openrc` |

#### Scenario: Missing image is built by update

- **WHEN** full-path work needs an image and the default product tag is absent
- **THEN** `update` generates a recipe and `docker build`s it rather than telling the operator to run `docker build` as the only path

#### Scenario: No go.dev tarball

- **WHEN** ensure installs Go to meet a `go.mod` floor
- **THEN** that install is a Gentoo `dev-lang/go` or `go-bin` (binpkg or compile) and not a go.dev archive fetch

#### Scenario: amd64 recipe uses OpenRC flavor tag

- **WHEN** the host machine is `x86_64` and ensure generates a Dockerfile
- **THEN** the recipe `FROM` is `gentoo/stage3:amd64-openrc@sha256:<digest>` with the recorded base digest
- **AND** the recipe does not contain `FROM gentoo/stage3:amd64@` or `FROM gentoo/stage3:amd64 `

#### Scenario: KEYWORDS token is not the Hub tag

- **WHEN** the host machine is `ppc64le` and ensure generates a Dockerfile that installs overlay bun-bin
- **THEN** `FROM` names `gentoo/stage3:ppc64le-openrc` pinned by digest
- **AND** bun-bin `package.accept_keywords` uses `~ppc64`

#### Scenario: Testing SBCL floor is unmasked per-atom

- **WHEN** a full-path Sbcl unit’s floor is `2.6.6` and gentoo `dev-lisp/sbcl-2.6.6` is `~amd64` only (no `sbcl-bin` package)
- **THEN** the generated recipe emerges `>=dev-lisp/sbcl-2.6.6` once
- **AND** it contains `>=dev-lisp/sbcl-2.6.6::gentoo ~amd64`
- **AND** it does not contain a shell fallback `emerge` of `dev-lisp/sbcl-bin`

#### Scenario: rust-bin is preferred when only testing meets the floor

- **WHEN** the Rust floor is `1.88.0`, `dev-lang/rust-bin` has a host-arch ebuild ≥ that floor keyworded only `~amd64`, and `dev-lang/rust` has a plain `amd64` ebuild ≥ that floor
- **THEN** the recipe emerges `dev-lang/rust-bin` (not `dev-lang/rust`)
- **AND** it writes `>=dev-lang/rust-bin-<floor>::gentoo ~amd64`

#### Scenario: Image SBCL has no source USE

- **WHEN** the recipe emerges `dev-lisp/sbcl` to meet a floor
- **THEN** that atom does not enable `USE=source`

#### Scenario: Portage RUNs share three stable cache ids

- **WHEN** ensure generates a Dockerfile that emerges at least one toolchain
- **THEN** each Portage `RUN` cache-mounts `/var/cache/distfiles` with id `mndz-materialize-distfiles`, `/var/cache/binpkgs` with id `mndz-materialize-binpkgs`, and `/var/cache/binhost` with id `mndz-materialize-binhost`
- **AND** the recipe emerges `app-portage/gentoolkit`

### Requirement: Image satisfies the union of previous and this prepare’s floors

The program SHALL treat the materialize image as satisfying a prepare when every toolchain that prepare will use for full-path work is present in the image at a version greater than or equal to that prepare’s maximum required floor (Go from `go.mod`, Node from `engines.node`, Bun from `engines.bun` / overlay bun-bin including hypothetical working-plan floors for withheld Bun consumers, Rust and SBCL from their existing plan floors) **and**, when this prepare’s recipe will emerge overlay `dev-lisp/qlot`, the recorded image provides overlay qlot at a version greater than or equal to the PV that recipe would emerge **and**, when this prepare’s recipe will emerge overlay `dev-build/node-gyp`, the recorded image provides overlay node-gyp at a version greater than or equal to the PV that recipe would emerge. **This prepare’s** needed floors SHALL be the maximum requirement of classified **full-path** PV units only, including withheld hypo-planned Bun consumers as specified above. Reuse-path and GitMv units SHALL NOT contribute Go/Node/Bun/Rust/SBCL floors. The overlay qlot PV used for satisfy and for the recipe SHALL be the newest non-live overlay qlot ebuild (after qlot GitMv file work when that work must precede `docker build`). The overlay node-gyp PV used for satisfy and for the recipe SHALL be the newest non-live overlay node-gyp ebuild (after node-gyp file work when that work must precede `docker build`). Planned PVs of the same package that are not full-path in this prepare SHALL NOT raise language floors. When ensure must build, the resulting image SHALL satisfy the **union** of the previous image’s recorded satisfies (if any) and this prepare’s needed floors and qlot PV and node-gyp PV (monotonic; the program SHALL NOT drop a toolchain already paid for). When that union already holds and the recorded image id still exists, ensure SHALL NOT `docker build` unless the image base freshness check finds a newer stage3 digest, as specified in this capability. When overlay qlot PV is newer than the recorded image’s qlot, or overlay node-gyp PV is newer than the recorded image’s node-gyp, ensure SHALL `docker build` even if language floors and generator identity would otherwise satisfy.

#### Scenario: Already satisfies skips build

- **WHEN** `image.json` records Go 1.26.5 and this prepare’s full-path units need Go 1.26.4
- **THEN** ensure does not `docker build`

#### Scenario: First ralph-only run does not compile unused SBCL

- **WHEN** there is no previous image and this prepare’s full-path units are Bun-only
- **THEN** the built image is not required to include SBCL solely to preempt a later package
- **AND** a later prepare that needs SBCL may build again adding that toolchain

#### Scenario: Later prepare keeps prior Go

- **WHEN** the current image satisfies Go 1.26.5 and this prepare needs Bun 1.3 and not a newer Go
- **THEN** the image after ensure still provides Go at least 1.26.5

#### Scenario: Reuse sibling PV does not raise the floor

- **WHEN** a package has a full-path unit whose requirement is Go 1.24.0 and a reuse-path unit whose requirement is Go 1.26.5
- **THEN** this prepare’s Go floor is 1.24.0
- **AND** the generated recipe is not required to accept testing keywords solely for 1.26.5

#### Scenario: Newer overlay qlot rebuilds

- **WHEN** `image.json` records overlay qlot `1.8.4` and generator identity matches, language floors would satisfy, and overlay qlot’s newest non-live PV is `1.8.5`
- **THEN** ensure `docker build`s
- **AND** the new sidecar records qlot at least `1.8.5`

#### Scenario: Newer overlay node-gyp rebuilds

- **WHEN** `image.json` records overlay node-gyp `13.0.0` and generator identity matches, language floors would satisfy, and overlay node-gyp’s newest non-live PV is `13.0.1`
- **THEN** ensure `docker build`s
- **AND** the new sidecar records node-gyp at least `13.0.1`

### Requirement: Sidecar records the one current image

When the check/cache XDG layout applies, the program SHALL store materialize image metadata under `${XDG_CACHE_HOME}/mndz/overlay-manager/materialize` when `XDG_CACHE_HOME` is set and non-empty, and under `${HOME}/.cache/mndz/overlay-manager/materialize` otherwise. That directory SHALL contain a file named `image.json` describing the current image (at least image id, satisfies floors, generator identity, built-at, the managed tree commit the image was built from, the stage3 base digest, and the time of the last successful base freshness check) and the last generated `Dockerfile` (or equivalent recipe) that produced it. The program SHALL NOT keep a catalog of previous image ids as required state.

#### Scenario: Default sidecar path

- **WHEN** `XDG_CACHE_HOME` is unset, `HOME` is `/home/op`, and ensure writes metadata
- **THEN** files are stored under `/home/op/.cache/mndz/overlay-manager/materialize/` including `image.json`

#### Scenario: Sidecar records tree and base

- **WHEN** ensure builds an image from managed tree commit `C` and stage3 digest `D`
- **THEN** `image.json` records `C`, `D`, and the base check time

## ADDED Requirements

### Requirement: Image builds read the managed tree

Each recipe `RUN` that invokes Portage SHALL bind the managed Gentoo tree read-only at `/var/db/repos/gentoo` from a build context that excludes the tree's git metadata. The recipe SHALL NOT run `emerge-webrsync` or another tree sync, and the built image SHALL NOT contain a Gentoo tree at `/var/db/repos/gentoo`.

#### Scenario: No baked tree

- **WHEN** ensure builds the materialize image
- **THEN** the generated recipe contains no `emerge-webrsync`
- **AND** a container from the built image without a bind has no ebuilds under `/var/db/repos/gentoo`

#### Scenario: Build sees the planning tree

- **WHEN** ensure chose atoms from managed tree commit `C`
- **THEN** every Portage `RUN` in that build resolves against commit `C`

#### Scenario: Git metadata stays out of the build

- **WHEN** ensure builds with the managed tree as a build context
- **THEN** the tree's `.git` directory is not sent to the builder

### Requirement: Base step updates the world set

The recipe's base step SHALL run `emerge --update --deep --newuse @world` after upgrading Portage and before any toolchain step, so every built image has the base packages current with the managed tree commit it was built from.

#### Scenario: Stale stage3 packages are updated

- **WHEN** the stage3 base ships `net-misc/curl` older than the version in the managed tree
- **THEN** the built image has the managed tree's `net-misc/curl` version

### Requirement: Tree changes alone do not trigger a build

Ensure SHALL NOT `docker build` solely because the managed tree commit differs from the one recorded in `image.json`. When ensure does build for another reason, the build SHALL use the current managed tree commit.

#### Scenario: Synced tree leaves a satisfying image

- **WHEN** the managed tree moved to a new commit, the recorded image satisfies this prepare's floors, and the base check is not due
- **THEN** ensure does not `docker build`

### Requirement: Configurable base check interval

The program SHALL read optional config key `materialize-base-check-interval` as a human duration with the same syntax as `check-cache-ttl`, defaulting to three days. Invalid durations SHALL fail configuration load.

#### Scenario: Default interval

- **WHEN** config omits `materialize-base-check-interval`
- **THEN** the base freshness check is due three days after the last successful check

### Requirement: Base freshness check

When ensure runs for the default tag and the base check is due, the program SHALL read the current digest of the `gentoo/stage3` tag from the registry without pulling the image. A different digest SHALL make ensure `docker build` with the new digest. The same digest SHALL record a successful check without building. A failed check SHALL keep the image, warn, and leave the check due.

#### Scenario: Newer stage3 rebuilds

- **WHEN** the base check is due and the registry digest for `amd64-openrc` differs from the recorded digest
- **THEN** ensure builds a new image from the new digest even though floors are satisfied
- **AND** the new sidecar records the new digest

#### Scenario: Same stage3 resets the timer

- **WHEN** the base check is due and the registry digest equals the recorded digest
- **THEN** ensure does not build and records the check time, so the next check is due one interval later

#### Scenario: Registry unreachable

- **WHEN** the base check is due and the registry request fails
- **THEN** ensure keeps the current image, logs a warning, and the check remains due for the next run

#### Scenario: Override tag skips the check

- **WHEN** `MNDZ_MATERIALIZE_IMAGE` is set
- **THEN** the program does not run the base freshness check

### Requirement: Base-only image for Portage tools

When the Portage tools container needs an image and none is recorded, ensure SHALL build an image with no toolchains (stage3, base step, managed tree bound) and record it as the current image with empty satisfied floors. A later prepare that needs toolchains SHALL build on that image as for any union.

#### Scenario: GitMv-only update on a fresh host

- **WHEN** no image is recorded and `update` needs only GitMv Manifest work
- **THEN** ensure builds a base-only image and the Manifest runs in a tools container from it
- **AND** `image.json` records no toolchain floors
