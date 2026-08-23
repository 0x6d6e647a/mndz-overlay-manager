## MODIFIED Requirements

### Requirement: Image satisfies the union of previous and this prepare’s floors

The program SHALL treat the materialize image as satisfying a prepare when every toolchain that prepare will use for full-path work is present in the image at a version greater than or equal to that prepare’s maximum required floor (Go from `go.mod`, Node from `engines.node`, Bun from `engines.bun` / overlay bun-bin, Rust and SBCL from their existing plan floors). **This prepare’s** needed floors SHALL be the maximum requirement of classified **full-path** PV units only. Reuse-path and GitMv units SHALL NOT contribute floors. Planned PVs of the same package that are not full-path in this prepare SHALL NOT raise the floor. When ensure must build, the resulting image SHALL satisfy the **union** of the previous image’s recorded satisfies (if any) and this prepare’s needed floors (monotonic; the program SHALL NOT drop a toolchain already paid for). When that union already holds and the recorded image id still exists, ensure SHALL NOT `docker build`.

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

### Requirement: Bun in the image is overlay bun-bin only

When ensure must provide Bun, the image SHALL install `dev-lang/bun-bin::mndz` from the configured overlay (bind-mounted or otherwise visible to the build without copying the overlay git tree into an image layer as the package source). Portage in the build SHALL write distfiles and binpkgs to image cache locations, not into the overlay work tree. When that overlay atom is not plain-visible on the host architecture, the build SHALL write package-level `package.accept_keywords` of the form `>=dev-lang/bun-bin-<pv>::mndz ~<keywords-token>` and SHALL NOT set whole-image `ACCEPT_KEYWORDS` to `~arch` solely to install bun-bin.

#### Scenario: Ralph uses overlay bun-bin in the image

- **WHEN** ensure runs for full-path ralph-tui after a bun-bin overlay commit
- **THEN** the image Bun comes from emerging `dev-lang/bun-bin::mndz` at the committed overlay PV
- **AND** the overlay git tree is not used as Portage DISTDIR or PKGDIR

#### Scenario: bun-bin accept_keywords names repo and version

- **WHEN** the host machine is `x86_64` and ensure installs overlay bun-bin at PV `1.2.21` that is testing-keyworded
- **THEN** the recipe contains `>=dev-lang/bun-bin-1.2.21::mndz ~amd64`

## ADDED Requirements

### Requirement: Unsatisfiable toolchain floor hard-fails before docker build

When ensure will generate the default product tag and a needed toolchain floor has no host-arch ebuild (plain or tilde) in either the `-bin` package or the source package that meets the floor, the program SHALL hard-fail those full-path units (or the command before their mutate) with status `1` **before** `docker build`. The program SHALL NOT emit a recipe that trial-emerges a missing package, and SHALL NOT run host `go`, `npm`, `bun`, `sbcl`, or `pycargoebuild` instead. Override-tag inspect-only rules remain as already specified.

#### Scenario: No SBCL ebuild meets the floor

- **WHEN** a full-path Sbcl unit’s floor is `2.7.0` and gentoo has no `dev-lisp/sbcl` or `sbcl-bin` host-arch ebuild ≥ `2.7.0`
- **THEN** ensure fails with status `1` before `docker build`
- **AND** host language tools are not used instead
