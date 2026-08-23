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

### Requirement: GitMv and reuse overlap ensure; full-path waits

Ensure SHALL NOT occupy a package `--jobs` slot. Packages that do not need the image (GitMv, reuse-path DepsAndAssets) MAY start phase-1 while ensure runs. Full-path units SHALL NOT start language materialize until ensure has succeeded for their needed floors. Waiting on ensure SHALL NOT count as an in-flight package job.

#### Scenario: bun-bin overlaps first image build

- **WHEN** untargeted `update` needs work on `dev-lang/bun-bin` and on a full-path Cargo or Go package, and the materialize image is missing
- **THEN** bun-bin phase-1 may run while ensure builds the image
- **AND** the full-path package does not start container materialize until ensure succeeds

#### Scenario: Ensure does not take the only job

- **WHEN** `--jobs 1` and bun-bin needs work while a full-path package waits on ensure
- **THEN** bun-bin may occupy the job slot
- **AND** waiting on ensure does not occupy that slot

### Requirement: Re-ensure after overlay wait-edge provider commit

After an overlay wait-edge provider in this run creates a successful signed overlay commit, and withheld consumers are re-planned and classified with **new** full-path units, the program SHALL ensure the materialize image against those units’ floors (including overlay `dev-lang/bun-bin` now on committed disk) before admitting those units to language materialize. Ensure failure or missing `docker` at that re-entry SHALL hard-fail the affected consumers and SHALL NOT roll back the provider’s overlay commit.

#### Scenario: Second ensure after bun-bin commit

- **WHEN** untargeted `update` commits a newer `dev-lang/bun-bin` and re-planned `dev-util/ralph-tui` needs full-path work whose Bun floor exceeds the image from t0
- **THEN** ensure runs again before ralph-tui container materialize
- **AND** that ensure uses committed overlay `dev-lang/bun-bin::mndz`

#### Scenario: Failed re-ensure keeps bun-bin commit

- **WHEN** bun-bin has committed and ensure for ralph-tui full-path fails
- **THEN** ralph-tui hard-fails
- **AND** the bun-bin overlay commit remains

### Requirement: Image satisfies the union of previous and this prepare’s floors

The program SHALL treat the materialize image as satisfying a prepare when every toolchain that prepare will use for full-path work is present in the image at a version greater than or equal to that prepare’s maximum required floor (Go from `go.mod`, Node from `engines.node`, Bun from `engines.bun` / overlay bun-bin, Rust and SBCL from their existing plan floors). When ensure must build, the resulting image SHALL satisfy the **union** of the previous image’s recorded satisfies (if any) and this prepare’s needed floors (monotonic; the program SHALL NOT drop a toolchain already paid for). When that union already holds and the recorded image id still exists, ensure SHALL NOT `docker build`.

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

### Requirement: Generated Gentoo image; install order; no official tarballs

The program SHALL generate the Dockerfile (or equivalent build recipe) used by ensure. The image SHALL be Gentoo on the host CPU architecture. The generated `FROM` line SHALL name an official `gentoo/stage3` **glibc OpenRC** flavor tag mapped from the host machine (`uname -m`), not the Portage KEYWORDS token concatenated onto `gentoo/stage3:`. The program SHALL NOT use Hub tags `amd64` or `arm64` as `FROM`, SHALL NOT use `gentoo/stage3:latest` as the generated `FROM`, and SHALL NOT use systemd, musl, llvm, hardened, or desktop flavor tags for that `FROM`. Portage `package.accept_keywords` for overlay bun-bin SHALL keep using the Gentoo KEYWORDS token for the host (`amd64`, `arm64`, `ppc64`, `riscv`, `s390`, `x86`, `arm`). Toolchain install SHALL prefer a Gentoo `-bin` package, then a binpkg, then compile from source. The program SHALL NOT install Go, Node, Bun, Rust, or SBCL from upstream official tarball/zip URLs as a substitute for Portage. Overlay ebuild KEYWORDS and BDEPEND/RDEPEND SHALL remain as specified by runtime-lanes and ecosystem capabilities; the image is not an overlay package.

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

When ensure must provide Bun, the image SHALL install `dev-lang/bun-bin::mndz` from the configured overlay (bind-mounted or otherwise visible to the build without copying the overlay git tree into an image layer as the package source). Portage in the build SHALL write distfiles and binpkgs to image cache locations, not into the overlay work tree. The build SHALL accept that overlay atom for the host architecture (package-level accept of `~arch` when the ebuild is testing-keyworded) and SHALL NOT set whole-image `ACCEPT_KEYWORDS` to `~arch` solely to install bun-bin.

#### Scenario: Ralph uses overlay bun-bin in the image

- **WHEN** ensure runs for full-path ralph-tui after a bun-bin overlay commit
- **THEN** the image Bun comes from emerging `dev-lang/bun-bin::mndz` at the committed overlay PV
- **AND** the overlay git tree is not used as Portage DISTDIR or PKGDIR

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

When ensure will `docker build`, the program SHALL hard-fail before starting that build if free space on the Docker storage filesystem (and, when distinct, the overlay path used as a bind-mount) is below a conservative bound for the layers that build will run (full first image versus adding one toolchain). The program SHALL NOT attempt to subtract BuildKit cache hit-rate. When `image.json` already satisfies and no build will run, this check SHALL NOT fail the run solely for image-build space.

#### Scenario: Satisfies skips image disk gate

- **WHEN** the current image already satisfies this prepare
- **THEN** `update` does not hard-fail solely because Docker storage would be tight for a hypothetical full rebuild

#### Scenario: First build fails early on tiny disk

- **WHEN** there is no image, this prepare needs a full-path image, and Docker storage free space is below the conservative bound
- **THEN** ensure hard-fails before `docker build`
