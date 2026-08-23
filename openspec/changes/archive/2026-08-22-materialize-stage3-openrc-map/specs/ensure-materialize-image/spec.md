## MODIFIED Requirements

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

## ADDED Requirements

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
