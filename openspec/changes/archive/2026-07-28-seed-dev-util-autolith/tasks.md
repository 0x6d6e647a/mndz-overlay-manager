## 1. Deps asset helper and publish

- [x] 1.1 Add `mndz-overlay/autolith-make-deps-tarball.py` (Python 3; mirror style of `go-make-vendor-tarball.py`) that, given an Autolith checkout at tag `v0.17.2`, produces `autolith-0.17.2-deps.tar.xz` with top-level `.qlot/` (qlot install from lock) and `fff/` (commit from `native/fff/commit` + `cargo vendor`)
- [x] 1.2 Run the helper against a clean `v0.17.2` checkout; verify tarball layout and that fff builds with `cargo build --offline -p fff-c` from the packed tree
- [x] 1.3 Publish to mndz-overlay-assets: sidecars under `dev-util/autolith/`, commit message `dev-util/autolith: 0.17.2`, push, GitHub release tag `autolith-0.17.2` with the deps tarball asset

## 2. Overlay package

- [x] 2.1 Add `dev-util/autolith/metadata.xml` (GitHub remote-id `luciusmagn/autolith`)
- [x] 2.2 Write `autolith-0.17.2.ebuild`: `DESCRIPTION` / `HOMEPAGE` / `LICENSE="ISC"`; `KEYWORDS="~amd64 ~ppc ~ppc64 ~riscv ~x86"`; `IUSE="test"`; `RESTRICT="!test? ( test )"`
- [x] 2.3 `SRC_URI`: GitHub archive `v${PV}` + parameterized assets deps URL; `BDEPEND`/`RDEPEND` with `>=dev-lisp/sbcl-2.6.4:=[source]`, bubblewrap, openssl, git, rust/cargo as designed
- [x] 2.4 `src_prepare` / compile: floor-check SBCL; stamp `sbcl.version` to build PV; synthetic SBCL source root (fallback full unpack if needed); disable network runtime installer paths
- [x] 2.5 `src_compile`: unpack/use deps tarball offline; build fff offline; natives; fabricate git identity; build recovery/active cores (C lean A preferred)
- [x] 2.6 `src_install`: private prefix + `/usr/bin/autolith` wrapper exporting env; docs as appropriate
- [x] 2.7 `src_test`: minimal offline verification when USE=test
- [x] 2.8 Run `ebuild … manifest`, commit overlay package, regenerate package md5-cache if overlay practice requires

## 3. Operator smoke

- [x] 3.1 Emerge `=dev-util/autolith-0.17.2` (or the live `-rN` atom if a content revision was needed)
- [x] 3.2 Run `autolith --version` and confirm success / version 0.17.2
- [x] 3.3 Report smoke results; mark this change complete only after smoke passes
