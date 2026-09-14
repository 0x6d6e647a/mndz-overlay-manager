## MODIFIED Requirements

### Requirement: Generated Gentoo image; install order; no official tarballs

The program SHALL generate the Dockerfile (or equivalent build recipe) used by ensure. The image SHALL be Gentoo on the host CPU architecture. The generated `FROM` line SHALL name an official `gentoo/stage3` **glibc OpenRC** flavor tag mapped from the host machine (`uname -m`), not the Portage KEYWORDS token concatenated onto `gentoo/stage3:`. The program SHALL NOT use Hub tags `amd64` or `arm64` as `FROM`, SHALL NOT use `gentoo/stage3:latest` as the generated `FROM`, and SHALL NOT use systemd, musl, llvm, hardened, or desktop flavor tags for that `FROM`. Portage `package.accept_keywords` SHALL use the Gentoo KEYWORDS token for the host (`amd64`, `arm64`, `ppc64`, `riscv`, `s390`, `x86`, `arm`).

Before `docker build`, the program SHALL choose **one** Portage atom per needed toolchain by scanning the gentoo (or overlay, for bun-bin) package directories: if a `-bin` package exists and has a host-arch ebuild whose version is greater than or equal to the floor (plain or tilde KEYWORDS), that `-bin` atom SHALL be used; otherwise the corresponding source package SHALL be used when it likewise has such an ebuild. The generated recipe SHALL `emerge` that single atom (`>=` the floor, or unversioned when the floor token is any-version). The recipe SHALL NOT trial-emerge a missing `-bin` package with a shell `||` fallback. A local binpkg of the chosen atom SHALL be preferred over compiling (`usepkg` / PKGDIR, then `getbinpkg` from the configured binhost, then compile). After a successful merge the build SHALL write a binpkg (`buildpkg`) into the image’s PKGDIR cache mount.

Every recipe `RUN` that invokes Portage (`emerge`, `emerge-webrsync`, `getuto`, `eclean-pkg`, or `eclean-dist`) SHALL cache-mount all three of:

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

#### Scenario: Portage RUNs share three stable cache ids

- **WHEN** ensure generates a Dockerfile that emerges at least one toolchain
- **THEN** each Portage `RUN` cache-mounts `/var/cache/distfiles` with id `mndz-materialize-distfiles`, `/var/cache/binpkgs` with id `mndz-materialize-binpkgs`, and `/var/cache/binhost` with id `mndz-materialize-binhost`
- **AND** the recipe emerges `app-portage/gentoolkit`

## ADDED Requirements

### Requirement: Prune Portage caches after union toolchain install

When default-tag ensure `docker build`s, the generated recipe SHALL, **after** every toolchain and overlay-atom emerge step for that image, run `eclean-pkg --deep` and `eclean-dist --deep` in a Portage `RUN` that uses the same three cache mounts specified for emerge. That prune `RUN` SHALL report the sizes of `/var/cache/binhost`, `/var/cache/binpkgs`, and `/var/cache/distfiles` before and after those `eclean` commands (for example `du -sh` of each). The program SHALL NOT pass `--package-names` to `eclean-pkg`. Failure of that prune `RUN` SHALL fail ensure (the image is not recorded as satisfying the prepare).

The recipe SHALL NOT run `eclean-pkg --deep` or `eclean-dist --deep` before the first emerge of that build, and SHALL NOT run them at the end of an intermediate toolchain `RUN` while later toolchains in the same recipe have not yet been emerged. When ensure skips `docker build` (union already satisfies), the program SHALL NOT run those `eclean` commands. When `MNDZ_MATERIALIZE_IMAGE` is set, the program SHALL NOT run them. The program SHALL NOT run `docker builder prune` to reclaim Portage caches.

#### Scenario: Successful default-tag build prunes after toolchains

- **WHEN** ensure `docker build`s the default tag for a union that includes Go and SBCL
- **THEN** the generated recipe runs `eclean-pkg --deep` and `eclean-dist --deep` after those toolchain emerge steps
- **AND** that prune step cache-mounts the same three Portage cache ids as the emerge steps
- **AND** it does not pass `--package-names` to `eclean-pkg`

#### Scenario: Prune is not at the start of the build

- **WHEN** ensure generates a Dockerfile
- **THEN** `eclean-pkg --deep` and `eclean-dist --deep` do not appear before the first `emerge` in that recipe

#### Scenario: Satisfies skip does not prune caches

- **WHEN** `image.json` already satisfies this prepare and ensure does not `docker build`
- **THEN** the program does not run `eclean-pkg` or `eclean-dist`

#### Scenario: Override tag does not prune caches

- **WHEN** `MNDZ_MATERIALIZE_IMAGE` is set to a non-empty tag
- **THEN** the program does not run `eclean-pkg` or `eclean-dist` against BuildKit Portage caches

#### Scenario: Failed prune fails ensure

- **WHEN** default-tag `docker build` reaches the prune step and that step fails
- **THEN** ensure fails
- **AND** the sidecar is not recorded as a successful satisfy for this prepare
