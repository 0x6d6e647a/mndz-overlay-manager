## 1. Overlay package

- [x] 1.1 Inventory Gentoo `licenses/` tokens for qlot MIT and every `.bundle-libs/software/*` project in `qlot-1.8.4.tar.gz`; add overlay `licenses/` files only if a token is missing
- [x] 1.2 Add `dev-lisp/qlot/metadata.xml` with GitHub remote-id `fukamachi/qlot`
- [x] 1.3 Write `qlot-1.8.4.ebuild`: `DESCRIPTION` / `HOMEPAGE`; inventoried `LICENSE`; `S="${WORKDIR}/qlot"`; `SRC_URI` GitHub release `qlot-${PV}.tar.gz` only; `KEYWORDS` tilde SBCL arches; `IUSE="test"`; `RESTRICT="!test? ( test )"`; `RDEPEND`/`BDEPEND` `dev-lisp/sbcl` (no `[source]`), `dev-libs/openssl:=`, `dev-vcs/git`
- [x] 1.4 `src_compile`: export `SBCL_HOME` and throwaway `HOME`; die if `.bundle-libs/setup.lisp` missing; run `scripts/setup.sh`; do not run `scripts/install.sh`; do not fetch `beta.quicklisp.org`
- [x] 1.5 `src_install`: tree under `/usr/share/qlot`; executable trampoline scripts; `dosym` `/usr/bin/qlot` → `/usr/share/qlot/bin/qlot`; no `common-lisp-3`; no `systems/qlot.asd` symlink
- [x] 1.6 `src_test`: minimal offline `qlot --version` or bundle load when USE=test
- [x] 1.7 Confirm `dev-util/autolith` ebuild is unchanged (no qlot `DEPEND`)
- [x] 1.8 Run `ebuild … manifest` and package `egencache`; commit the overlay package tree

## 2. Operator smoke

- [x] 2.1 Emerge `=dev-lisp/qlot-1.8.4` (or the live `-rN` atom if a content revision was needed)
- [x] 2.2 Run `qlot --version` from `PATH` and confirm it prints 1.8.4 (upstream exit 255 after print is accepted)
- [x] 2.3 Report smoke results; mark this change complete only after smoke passes

## 3. Manager OpenSpec gate

- [x] 3.1 `openspec validate seed-dev-lisp-qlot --strict --type change`
- [x] 3.2 `hk check` on mndz-overlay-manager (planning artifacts only; no Haskell)
