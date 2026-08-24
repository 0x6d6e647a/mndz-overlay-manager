## Why

The materialize image still bootstraps qlot by fetching an unpinned Quicklisp installer at `docker build` time. Gentoo and the mndz overlay have no `dev-lisp/qlot` atom, so that layer cannot `emerge` a Manifest-hashed tool the way it emerges overlay `dev-lang/bun-bin`. A hand-seeded overlay qlot package is the prerequisite for a later manager change that replaces that fetch.

## What Changes

- Add `dev-lisp/qlot` at upstream **1.8.4** to **mndz-overlay** (ebuild, `metadata.xml`, Manifest, package `egencache` / md5-cache as required by overlay practice).
- `SRC_URI` is the GitHub **release** tarball `qlot-${PV}.tar.gz` (contains `.bundle-libs/`; not the git-tag archive). No `mndz-overlay-assets` distfile.
- Install the unpacked tree under `/usr/share/qlot` and symlink `/usr/bin/qlot` → `/usr/share/qlot/bin/qlot`. Do not inherit `common-lisp-3`. Do not symlink `qlot.asd` into `/usr/share/common-lisp/systems`.
- `src_compile` exports `SBCL_HOME` in the ebuild and runs upstream `scripts/setup.sh` against the bundled libs (no `beta.quicklisp.org`). Do not run `scripts/install.sh` (it symlinks `${S}` into `/usr/local`).
- `LICENSE` enumerates Gentoo tokens for qlot (MIT) **and** every library shipped under `.bundle-libs/software/`.
- `RDEPEND`/`BDEPEND`: `dev-lisp/sbcl` (no `[source]`), `dev-libs/openssl:=`, `dev-vcs/git`.
- KEYWORDS: Gentoo `dev-lisp/sbcl` arch set, overlay tilde-only (`~amd64 ~ppc ~ppc64 ~riscv ~sparc ~x86 ~x64-macos`). No `~arm64`. No `-*`.
- Do **not** add qlot to `dev-util/autolith` `DEPEND`.
- Operator smoke: emerge `=dev-lisp/qlot-1.8.4` and run `qlot version` (or equivalent) with `qlot` on `PATH`.

## Non-goals

- No mndz-overlay-manager Haskell, image recipe, `materializeGeneratorId`, or `Update.Sbcl.Deps` retarget (see later `materialize-overlay-qlot`).
- No `dev-lisp/quicklisp` client package (release tarball already vendors `.bundle-libs`).
- No Autolith FHS split or Autolith `LICENSE` inventory (see `autolith-split-handoff.md` / `revise-dev-util-autolith-fhs-license`).
- No manager GitMv policy for qlot (seed-and-pin; document GitMv as a future option only).
- No Roswell; no rolling un-versioned Quicklisp dist; no `common-lisp-3` global registry.
- No `~arm64` (Gentoo SBCL is not keyworded there).

## Capabilities

### New Capabilities

- `dev-lisp-qlot-seed`: Requirements for the manually seeded `dev-lisp/qlot` overlay package (release tarball, install layout, compile sandbox, LICENSE inventory, KEYWORDS, dependencies, Autolith isolation, operator smoke).

### Modified Capabilities

- (none — this change does not alter manager product requirements)

## Impact

- **mndz-overlay**: new package tree `dev-lisp/qlot/` (ebuild, Manifest, `metadata.xml`, md5-cache).
- **mndz-overlay-assets**: none.
- **mndz-overlay-manager**: planning artifacts only; no implementation in this change.
- **Operator**: manual emerge + `qlot` on `PATH` after overlay commit.
- **Downstream**: enables `materialize-overlay-qlot` (image `emerge ::mndz`, drop Quicklisp installer fetch).
