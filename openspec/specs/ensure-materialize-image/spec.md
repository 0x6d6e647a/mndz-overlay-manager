# ensure-materialize-image Specification

## Purpose

When `update` will full-path materialize DepsAndAssets units, it ensures a host-architecture Gentoo Docker image that satisfies those units’ toolchain floors, without an operator `docker build` prerequisite and without host language-toolchain fallback.

## Requirements

### Requirement: Ensure runs only for full-path units that will mutate

When `update` has classified at least one DepsAndAssets unit as **full path** and that unit is eligible to mutate (admitted, or newly admitted after overlay wait-edge re-plan), the program SHALL ensure a product materialize image for the host CPU architecture before that unit’s language materialize starts. `list`, `outdated`, reuse-only `update`, and GitMv-only work SHALL NOT require an image or `docker build`. Missing `docker` on `PATH` when a full-path unit will mutate SHALL hard-fail those units (or the spine when no mutate has started) with status `1` and SHALL NOT run host `go`, `npm`, `bun`, `sbcl`, or `pycargoebuild` instead.

#### Scenario: Reuse-only skips ensure

- **WHEN** every DepsAndAssets unit that needs work is classified reuse
- **THEN** `update` does not `docker build` and does not fail solely because the materialize image is missing

#### Scenario: GitMv-only skips ensure

- **WHEN** the only needs-work package is `dev-lang/bun-bin` (`GitMvAndManifest`)
- **THEN** `update` does not require a usable materialize image

#### Scenario: No docker hard-fails full-path

- **WHEN** `update` will full-path materialize at least one unit and `docker` is not on `PATH`
- **THEN** those full-path units (or the command before their mutate) fail with status `1` and host language tools are not used instead

### Requirement: Overlay bun-bin is emergeable before docker build

When ensure will `docker build` a recipe that `emerge`s `dev-lang/bun-bin::mndz`, the program SHALL NOT start that `docker build` until the overlay bun-bin package directory on disk has:

1. a non-live ebuild whose version equals the PV in that recipe’s bun-bin atom, and
2. a package `Manifest` with DIST checksum entries for the distfile names that ebuild’s `SRC_URI` will fetch for the host architecture, and
3. package-scoped Portage `egencache` metadata for that ebuild as specified by `md5-cache`.

Independent GitMv packages that the image does not emerge (`dev-util/grok-build-bin`, `dev-lang/deno-bin`) SHALL NOT be required to finish before that `docker build`. Overlay bind SHALL remain the configured overlay worktree (read-only at build); the program SHALL NOT require the bun-bin signed overlay commit to exist before `docker build`.

#### Scenario: Docker waits on bun-bin Manifest

- **WHEN** ensure will emerge `>=dev-lang/bun-bin-1.4.0::mndz` and overlay bun-bin has been renamed to `bun-bin-1.4.0.ebuild` but Manifest DIST lines are still `bun-bin-1.3.14-*`
- **THEN** `docker build` does not start until `ebuild … manifest` (and package `egencache`) for that ebuild have succeeded

#### Scenario: grok-build-bin does not gate docker

- **WHEN** ensure will emerge overlay bun-bin and `dev-util/grok-build-bin` also needs GitMv work
- **THEN** grok-build-bin phase-1 may overlap `docker build`
- **AND** docker is not required to wait on grok-build-bin Manifest or commit

#### Scenario: Commit is not required before docker

- **WHEN** bun-bin `ebuild … manifest` and package `egencache` have succeeded for PV `1.4.0` and the signed overlay commit has not yet been created
- **THEN** ensure MAY `docker build` emerging `dev-lang/bun-bin-1.4.0::mndz` from the worktree bind

### Requirement: This prepare’s floors include hypo-planned withheld Bun full-path units

When Bun consumers are withheld on a selected bun-bin that needs work, **this prepare’s** needed floors for the t0 ensure SHALL include classified **full-path** PV units from those consumers’ hypothetical working plans, even though those consumers are not yet admitted to mutate. Reuse-path and GitMv units still SHALL NOT contribute floors. The program SHALL NOT omit those Bun floors solely because the consumers are withheld.

#### Scenario: First ensure includes ralph hypo bun floor

- **WHEN** untargeted `update` withholds ralph-tui on bun-bin needs-work, ralph-tui’s hypothetical plan has a full-path unit requiring bun `1.4.0`, and a Go package is also full-path
- **THEN** t0 ensure’s bun floor is at least `1.4.0`
- **AND** the generated recipe emerges overlay bun-bin at that PV

### Requirement: GitMv and reuse overlap ensure; full-path waits

Ensure SHALL NOT occupy a package `--jobs` slot. Packages that do not need the image (independent GitMv such as `grok-build-bin`, reuse-path DepsAndAssets) MAY start phase-1 while ensure runs. When the recipe will emerge overlay bun-bin, bun-bin GitMv **file** work (rename, `ebuild … manifest`, package `egencache`) SHALL complete before that `docker build` as specified above; bun-bin’s signed overlay commit SHALL follow `update-apply` (after ensure finishes when ensure ran). Full-path units SHALL NOT start language materialize until ensure has succeeded for their needed floors **and** any overlay wait-edge predecessor that was needs-work has a signed overlay commit as specified by `overlay-apply-waves`. Waiting on ensure SHALL NOT count as an in-flight package job.

#### Scenario: bun-bin overlaps first image build

- **WHEN** untargeted `update` needs work on `dev-lang/bun-bin` and on a full-path Cargo or Go package, and the materialize image is missing
- **THEN** bun-bin rename, Manifest, and egencache complete before a bun-layer `docker build`
- **AND** the full-path package does not start container materialize until ensure succeeds
- **AND** bun-bin’s signed overlay commit MAY be delayed until ensure finishes as specified by `update-apply`

#### Scenario: bun-bin file work precedes bun-layer docker

- **WHEN** untargeted `update` needs work on `dev-lang/bun-bin` and on a full-path Go package, and the materialize image recipe will emerge overlay bun-bin
- **THEN** bun-bin rename, Manifest, and egencache complete before that `docker build`
- **AND** the Go package does not start container materialize until ensure succeeds

#### Scenario: grok-build-bin overlaps first image build

- **WHEN** untargeted `update` needs work on `dev-util/grok-build-bin` and on a full-path Go package, and the materialize image is missing
- **THEN** grok-build-bin phase-1 may run while ensure builds the image
- **AND** the full-path package does not start container materialize until ensure succeeds

#### Scenario: Ensure does not take the only job

- **WHEN** `--jobs 1` and bun-bin needs work while a full-path package waits on ensure
- **THEN** bun-bin may occupy the job slot for its file work
- **AND** waiting on ensure does not occupy that slot

### Requirement: Re-ensure after overlay wait-edge provider commit

After an overlay wait-edge provider in this run creates a successful signed overlay commit, the program SHALL NOT `docker build` again **solely** because that provider committed when t0 ensure already used the consumers’ hypothetical bun floors. If newly admitted consumers still need an image that does not satisfy their floors (for example `MNDZ_MATERIALIZE_IMAGE` inspect-only miss, or t0 ensure was skipped because no full-path unit existed yet), ensure SHALL run as specified for a prepare. Ensure failure or missing `docker` at that admit SHALL hard-fail the affected consumers and SHALL NOT roll back the provider’s overlay commit.

#### Scenario: Second ensure after bun-bin commit

- **WHEN** untargeted `update` commits a newer `dev-lang/bun-bin` and hypo-planned `dev-util/ralph-tui` needs full-path work whose Bun floor was already included in t0 ensure
- **THEN** ensure does not `docker build` again solely because bun-bin committed
- **AND** ralph-tui uses the t0 image after bun-bin’s signed overlay commit

#### Scenario: Failed re-ensure keeps bun-bin commit

- **WHEN** bun-bin has committed and ralph-tui full-path still needs a usable image that is missing
- **THEN** ralph-tui hard-fails
- **AND** the bun-bin overlay commit remains

#### Scenario: No second docker build after bun-bin commit

- **WHEN** t0 ensure already emerged overlay bun-bin `1.4.0` for hypo-planned ralph-tui full-path floors and bun-bin then commits `1.4.0`
- **THEN** ensure does not `docker build` again solely because bun-bin committed
- **AND** ralph-tui may start container materialize against that image after bun-bin’s signed commit

#### Scenario: Failed ensure after bun-bin commit keeps the commit

- **WHEN** bun-bin has committed and ralph-tui full-path still needs a usable image that is missing (`docker` not on `PATH` at admit)
- **THEN** ralph-tui hard-fails
- **AND** the bun-bin overlay commit remains

### Requirement: Image satisfies the union of previous and this prepare’s floors

The program SHALL treat the materialize image as satisfying a prepare when every toolchain that prepare will use for full-path work is present in the image at a version greater than or equal to that prepare’s maximum required floor (Go from `go.mod`, Node from `engines.node`, Bun from `engines.bun` / overlay bun-bin including hypothetical working-plan floors for withheld Bun consumers, Rust and SBCL from their existing plan floors). **This prepare’s** needed floors SHALL be the maximum requirement of classified **full-path** PV units only, including withheld hypo-planned Bun consumers as specified above. Reuse-path and GitMv units SHALL NOT contribute floors. Planned PVs of the same package that are not full-path in this prepare SHALL NOT raise the floor. When ensure must build, the resulting image SHALL satisfy the **union** of the previous image’s recorded satisfies (if any) and this prepare’s needed floors (monotonic; the program SHALL NOT drop a toolchain already paid for). When that union already holds and the recorded image id still exists, ensure SHALL NOT `docker build`.

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

### Requirement: Generated Gentoo image; install order; no official tarballs

The program SHALL generate the Dockerfile (or equivalent build recipe) used by ensure. The image SHALL be Gentoo on the host CPU architecture. The generated `FROM` line SHALL name an official `gentoo/stage3` **glibc OpenRC** flavor tag mapped from the host machine (`uname -m`), not the Portage KEYWORDS token concatenated onto `gentoo/stage3:`. The program SHALL NOT use Hub tags `amd64` or `arm64` as `FROM`, SHALL NOT use `gentoo/stage3:latest` as the generated `FROM`, and SHALL NOT use systemd, musl, llvm, hardened, or desktop flavor tags for that `FROM`. Portage `package.accept_keywords` SHALL use the Gentoo KEYWORDS token for the host (`amd64`, `arm64`, `ppc64`, `riscv`, `s390`, `x86`, `arm`).

Before `docker build`, the program SHALL choose **one** Portage atom per needed toolchain by scanning the gentoo (or overlay, for bun-bin) package directories: if a `-bin` package exists and has a host-arch ebuild whose version is greater than or equal to the floor (plain or tilde KEYWORDS), that `-bin` atom SHALL be used; otherwise the corresponding source package SHALL be used when it likewise has such an ebuild. The generated recipe SHALL `emerge` that single atom (`>=` the floor, or unversioned when the floor token is any-version). The recipe SHALL NOT trial-emerge a missing `-bin` package with a shell `||` fallback. A local binpkg of the chosen atom SHALL be preferred over compiling (`usepkg` / PKGDIR, then `getbinpkg` from the configured binhost, then compile). After a successful merge the build SHALL write a binpkg (`buildpkg`) into the image’s PKGDIR cache mount. That cache mount SHALL use a stable BuildKit cache id so a later recipe or generator rebuild can reuse it. The program SHALL NOT install Go, Node, Bun, Rust, or SBCL from upstream official tarball/zip URLs as a substitute for Portage. Overlay ebuild KEYWORDS and BDEPEND/RDEPEND SHALL remain as specified by runtime-lanes and ecosystem capabilities; the image is not an overlay package. Image SBCL SHALL NOT enable `USE=source`.

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
- **THEN** the recipe `FROM` is `gentoo/stage3:amd64-openrc`
- **AND** the recipe does not contain `FROM gentoo/stage3:amd64`

#### Scenario: KEYWORDS token is not the Hub tag

- **WHEN** the host machine is `ppc64le` and ensure generates a Dockerfile that installs overlay bun-bin
- **THEN** `FROM` is `gentoo/stage3:ppc64le-openrc`
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

### Requirement: Unmapped host architecture fails before docker build

When ensure will generate and `docker build` the default product tag, and the host `uname -m` is not in the mapping table, the program SHALL hard-fail those full-path units (or the command before their mutate) with status `1` **before** `docker build`. The error SHALL name the host machine arch. The program SHALL NOT emit `FROM gentoo/stage3:` plus the raw `uname -m` or KEYWORDS token as a substitute tag, and SHALL NOT run host `go`, `npm`, `bun`, `sbcl`, or `pycargoebuild` instead. When `MNDZ_MATERIALIZE_IMAGE` is set to a non-empty override, this mapping miss SHALL NOT by itself fail: override remains inspect-only as already specified.

#### Scenario: sparc full-path hard-fails without docker build

- **WHEN** `update` will full-path materialize at least one unit, `MNDZ_MATERIALIZE_IMAGE` is unset, and the host `uname -m` is `sparc64`
- **THEN** ensure fails with status `1` before `docker build`
- **AND** the error names `sparc64`
- **AND** host language tools are not used instead

#### Scenario: Override on unmapped arch does not generate

- **WHEN** `MNDZ_MATERIALIZE_IMAGE` is `example/materialize:ci`, that image is usable, and the host `uname -m` is `sparc64`
- **THEN** the program does not `docker build`
- **AND** it does not fail solely because `sparc64` has no official stage3 flavor

### Requirement: Generator identity mismatch is a miss

The program SHALL treat the sidecar as not satisfying a prepare when the recorded generator identity is missing or does not equal the identity of the current recipe generator, even if recorded floors would otherwise satisfy and the recorded image id still exists. In that case ensure SHALL `docker build` (unless an override tag is set, in which case override inspect-only rules apply). After a successful default-tag build, the sidecar SHALL record the current generator identity.

#### Scenario: Old generator rebuilds despite floors

- **WHEN** `image.json` records floors that would satisfy this prepare and an image id that still exists, but the recorded generator identity is not the current generator
- **THEN** ensure `docker build`s a new default-tag image
- **AND** the new sidecar records the current generator identity

### Requirement: Bun in the image is overlay bun-bin only

When ensure must provide Bun, the image SHALL install `dev-lang/bun-bin::mndz` from the configured overlay (bind-mounted or otherwise visible to the build without copying the overlay git tree into an image layer as the package source). Portage in the build SHALL write distfiles and binpkgs to image cache locations, not into the overlay work tree. When that overlay atom is not plain-visible on the host architecture, the build SHALL write package-level `package.accept_keywords` of the form `>=dev-lang/bun-bin-<pv>::mndz ~<keywords-token>` and SHALL NOT set whole-image `ACCEPT_KEYWORDS` to `~arch` solely to install bun-bin. The PV in that atom SHALL be the bun floor for this prepare (hypothetical remote when bun-bin is selected and needs work).

#### Scenario: Ralph uses overlay bun-bin in the image

- **WHEN** ensure runs for full-path ralph-tui whose hypothetical bun floor is overlay bun-bin `1.4.0` after bun-bin Manifest regeneration
- **THEN** the image Bun comes from emerging `dev-lang/bun-bin::mndz` at PV `1.4.0` from the overlay worktree bind
- **AND** the overlay git tree is not used as Portage DISTDIR or PKGDIR

#### Scenario: bun-bin accept_keywords names repo and version

- **WHEN** the host machine is `x86_64` and ensure installs overlay bun-bin at PV `1.2.21` that is testing-keyworded
- **THEN** the recipe contains `>=dev-lang/bun-bin-1.2.21::mndz ~amd64`

### Requirement: Unsatisfiable toolchain floor hard-fails before docker build

When ensure will generate the default product tag and a needed toolchain floor has no host-arch ebuild (plain or tilde) in either the `-bin` package or the source package that meets the floor, the program SHALL hard-fail those full-path units (or the command before their mutate) with status `1` **before** `docker build`. The program SHALL NOT emit a recipe that trial-emerges a missing package, and SHALL NOT run host `go`, `npm`, `bun`, `sbcl`, or `pycargoebuild` instead. Override-tag inspect-only rules remain as already specified.

#### Scenario: No SBCL ebuild meets the floor

- **WHEN** a full-path Sbcl unit’s floor is `2.7.0` and gentoo has no `dev-lisp/sbcl` or `sbcl-bin` host-arch ebuild ≥ `2.7.0`
- **THEN** ensure fails with status `1` before `docker build`
- **AND** host language tools are not used instead

### Requirement: Sidecar records the one current image

When the check/cache XDG layout applies, the program SHALL store materialize image metadata under `${XDG_CACHE_HOME}/mndz/overlay-manager/materialize` when `XDG_CACHE_HOME` is set and non-empty, and under `${HOME}/.cache/mndz/overlay-manager/materialize` otherwise. That directory SHALL contain a file named `image.json` describing the current image (at least image id, satisfies floors, generator identity, built-at) and the last generated `Dockerfile` (or equivalent recipe) that produced it. The program SHALL NOT keep a catalog of previous image ids as required state.

#### Scenario: Default sidecar path

- **WHEN** `XDG_CACHE_HOME` is unset, `HOME` is `/home/op`, and ensure writes metadata
- **THEN** files are stored under `/home/op/.cache/mndz/overlay-manager/materialize/` including `image.json`

### Requirement: Prune previous image after a successful mutate run

After `update` mutate finishes successfully enough to tear down the run workspace, if ensure replaced the product image, the program SHALL remove the previous product image id if nothing still uses it, then remove dangling images (`docker image prune` without deleting all unused tagged images). The program SHALL NOT run `docker image prune -a` or `docker builder prune` as part of ensure. The program SHALL NOT delete an image in the middle of mutate while other units may still `docker run` the previous id. The program SHALL NOT `docker rmi` a tag named only by a non-empty `MNDZ_MATERIALIZE_IMAGE` override the CLI did not build in this run.

#### Scenario: Successful ensure does not prune -a

- **WHEN** ensure built a new default-tag image and mutate completes
- **THEN** the previous default-tag image id may be removed if unused
- **AND** other tagged images on the daemon are not removed solely by a prune-all

#### Scenario: Override tag is not deleted

- **WHEN** `MNDZ_MATERIALIZE_IMAGE` names a tag the operator set
- **THEN** ensure does not `docker rmi` that tag

### Requirement: Override tag is inspect-only

When `MNDZ_MATERIALIZE_IMAGE` is set to a non-empty image tag, the program SHALL use that tag for `docker run` / inspect and SHALL NOT `docker build` or `docker rmi` it. If that image is missing or does not satisfy this prepare’s floors, those full-path units SHALL hard-fail.

#### Scenario: Override missing image hard-fails

- **WHEN** `MNDZ_MATERIALIZE_IMAGE` is `example/materialize:ci` and that image is not usable
- **THEN** full-path units fail
- **AND** the program does not `docker build` `example/materialize:ci`

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

### Requirement: Image SBCL locates its core without a login shell

When the generated recipe emerges SBCL to meet a floor, it SHALL set image environment `SBCL_HOME` to `/usr/<libdir>/sbcl` and `SBCL_SOURCE_ROOT` to `/usr/<libdir>/sbcl/src`. `<libdir>` SHALL be `lib64` when the host KEYWORDS token is `amd64`, `arm64`, `ppc64`, `riscv`, or `s390`, and `lib` when the token is `x86` or `arm`. Those environment settings SHALL take effect after the sbcl emerge step and before any recipe step that invokes `sbcl`. The recipe SHALL NOT rely on a login shell or `/etc/profile` to publish `SBCL_HOME`. Image SBCL SHALL still not enable `USE=source`.

#### Scenario: amd64 recipe exports lib64 SBCL_HOME

- **WHEN** the host machine is `x86_64` and the recipe emerges `dev-lisp/sbcl`
- **THEN** the recipe contains `ENV SBCL_HOME=/usr/lib64/sbcl`
- **AND** it contains `ENV SBCL_SOURCE_ROOT=/usr/lib64/sbcl/src`
- **AND** those `ENV` lines appear before the recipe invokes `sbcl`

#### Scenario: x86 recipe exports lib SBCL_HOME

- **WHEN** the host machine is `i686` and the recipe emerges `dev-lisp/sbcl`
- **THEN** the recipe contains `ENV SBCL_HOME=/usr/lib/sbcl`
- **AND** it contains `ENV SBCL_SOURCE_ROOT=/usr/lib/sbcl/src`

#### Scenario: bun-only recipe omits SBCL_HOME

- **WHEN** there is no previous image and this prepare’s full-path units are Bun-only
- **THEN** the generated recipe is not required to set `SBCL_HOME` solely because SBCL is unused

### Requirement: Quicklisp bootstrap fetch uses aria2c

When the generated recipe bootstraps image-local Quicklisp/qlot after emerging SBCL, it SHALL fetch the Quicklisp installer with `aria2c`. That fetch SHALL NOT use `wget`. The recipe MAY still install `wget` in the base layer for other tools.

#### Scenario: SBCL recipe fetches the installer with aria2c

- **WHEN** the recipe emerges SBCL and bootstraps Quicklisp
- **THEN** the installer URL is fetched with `aria2c`
- **AND** that fetch line does not invoke `wget`
