## Why

Autolith (a live, self-modifying Common Lisp AI agent) is not packaged in Gentoo or the mndz overlay. A hand-seeded `dev-util/autolith` ebuild at v0.17.2 (with a published offline deps asset including qlot lock tree and vendored fff) is the prerequisite for multiarch smoke, later automated manager updates, and an SBCL runtime-lane ecosystem in follow-on changes.

## What Changes

- Add `dev-util/autolith` version `0.17.2` to **mndz-overlay** (ebuild, `metadata.xml`, Manifest, md5-cache as required by overlay practice).
- Publish `autolith-0.17.2-deps.tar.xz` (and checksum sidecars) to **mndz-overlay-assets** under release tag `autolith-0.17.2`.
- Deps tarball contains full `.qlot/` after lock install **and** fff at the pinned commit with `cargo vendor` output (offline emerge; no network in `src_*`).
- Add overlay helper `autolith-make-deps-tarball.py` (same style as `go-make-vendor-tarball.py`); seed uses it to build the asset. Support-phase materialize logic later moves into mndz-overlay-manager Haskell.
- Ebuild: from-source app under private prefix (`/usr/lib/autolith/…`) + `/usr/bin/autolith` wrapper; `LICENSE="ISC"`; `DESCRIPTION` / `HOMEPAGE` per design.
- Runtime: `>=dev-lisp/sbcl-2.6.4:=[source]` (Gentoo only; stamp build SBCL PV into installed `sbcl.version`; synthetic `AUTOLITH_SBCL_SOURCE_ROOT` matching Gentoo `[source]` layout); RDEPEND bubblewrap, openssl, git as designed.
- Build: offline qlot tree from deps, fff via cargo `--offline`, colorlisp/sandbox natives, emerge-time cores (C lean A; fallback pure A); disable network SBCL install paths in packaged runtime.
- `IUSE="test"` with `RESTRICT="!test? ( test )"` and minimal offline `src_test`; no shell-completion USE (upstream has no bash/zsh/fish generator).
- KEYWORDS: `~amd64 ~ppc ~ppc64 ~riscv ~x86` (SBCL arches ≥ floor, tilde-only, minus arches without bubblewrap / SBCL keyword gaps).
- Operator acceptance: emerge `=dev-util/autolith-0.17.2` and run `autolith --version`.

## Non-goals

- No mndz-overlay-manager code, hardcoded policy, or SBCL ecosystem (see planned `support-dev-util-autolith`).
- No multiarch Docker probe execution in this change (see planned `probe-autolith-multiarch`; host prep: `~/mndz-overlay-manager-docker-setup.md`).
- No bump to v0.18.0 (leave headroom for support-phase smoke).
- No overlay `dev-lisp/sbcl` package; no `~arm64` KEYWORDS (Gentoo SBCL not keyworded for arm/arm64).
- No shell-completion eclass / bash-zsh-fish USE flags.
- No full upstream `script/check` as Portage `src_test`.

## Capabilities

### New Capabilities

- `dev-util-autolith-seed`: Requirements for the manually seeded `dev-util/autolith` ebuild, deps asset layout (`.qlot/` + vendored fff), SBCL floor and identity stamping, private install layout, USE/test/KEYWORDS, and acceptance smoke.

### Modified Capabilities

- (none — this change does not alter manager product requirements)

## Impact

- **mndz-overlay**: new package tree `dev-util/autolith/`; helper `autolith-make-deps-tarball.py`.
- **mndz-overlay-assets**: new release + sidecars under `dev-util/autolith/`.
- **mndz-overlay-manager**: planning artifacts only; no implementation in this change.
- **Operator**: manual emerge + `autolith --version` after publish.
- **Downstream**: enables `probe-autolith-multiarch` and `support-dev-util-autolith` (manager SBCL lanes + bump to 0.18.0).
