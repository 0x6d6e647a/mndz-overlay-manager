## Context

See `proposal.md` for motivation. Gentoo `::gentoo` has `dev-lisp/sbcl`, `asdf`, and `roswell`, not qlot. mndz-overlay has no `dev-lisp/` category tree yet (`dev-lisp` is a Gentoo category, so no overlay `profiles/categories` change is required).

qlot 1.8.4 GitHub **release** tarball (`qlot-1.8.4.tar.gz`, ~11 MB) unpacks to `qlot/` and includes `.bundle-libs/setup.lisp` plus `.bundle-libs/software/` (~40 vendored libraries). The git checkout does **not** include that bundle. Upstream `scripts/setup.sh` loads the bundle when present and does not hit `beta.quicklisp.org`. Upstream `scripts/install.sh` as root `ln -s` from `${S}` into `/usr/local` and cannot survive Portage deleting `${S}`. `bin/qlot` is a shell trampoline that follows symlinks and `exec`s `scripts/run.sh` with `--no-sysinit --no-userinit`.

Gentoo/GURU SBCL reverse deps: libraries use `common-lisp-3` (`/usr/share/common-lisp/source` + `systems/` symlinks); nyxt dumps a binary from a fat tarball; Autolith uses a private prefix. qlot README warns against putting the checkout on a recursive ASDF search path (`~/common-lisp`).

OpenSpec for this seed lives only in mndz-overlay-manager (overlay has no `openspec/` by policy). Implementation files land in mndz-overlay. No manager Haskell in this change.

Local clone for reading source: `/home/mndz/repos/com.github/fukamachi/qlot`. Distfile is the release asset, not that clone.

## Goals / Non-Goals

**Goals:**

- Ship `=dev-lisp/qlot-1.8.4` that emerges offline for qlot’s own Lisp deps and puts `qlot` on `PATH`.
- Encode layout, `SBCL_HOME` compile sandbox, LICENSE inventory, and KEYWORDS so a later manager change can `emerge ::mndz` this atom.

**Non-Goals:**

- Image recipe, `Update.Sbcl.Deps`, generator id (follow-on `materialize-overlay-qlot`).
- Separate `dev-lisp/quicklisp` package.
- Autolith layout/LICENSE revisions (`revise-dev-util-autolith-fhs-license`).
- Manager GitMv policy for qlot.

## Decisions

### 1. Package identity

- **Category/PN:** `dev-lisp/qlot` (lisp tool; same shelf as `roswell`, not `dev-util`).
- **PV:** `1.8.4` from release tag `1.8.4`.
- **Filename:** `qlot-1.8.4.ebuild` (no `-r0`; `-r1+` only for content-only fixes).
- **DESCRIPTION:** `Project-local Common Lisp library installer` (or equivalent short README synthesis).
- **HOMEPAGE:** `https://github.com/fukamachi/qlot`
- **metadata.xml:** GitHub remote-id `fukamachi/qlot`.

### 2. Distfile is the release tarball, not overlay-assets

- **Chosen:** `SRC_URI` GitHub release `qlot-${PV}.tar.gz`. `S="${WORKDIR}/qlot"`.
- **Why:** Spike listed `.bundle-libs/setup.lisp` in that asset. Overlay-assets exist for distfiles **we** pack (Autolith deps, Go vendor). This payload is upstream’s.
- **Alternative — git-tag archive:** skinny; `setup.sh` would install a live Quicklisp dist (the smell we are removing).
- **Alternative — overlay-assets copy of the same tarball:** extra publish path with no benefit.

### 3. Compile: setup.sh + SBCL_HOME, never install.sh

- Export `SBCL_HOME="${EPREFIX}/usr/$(get_libdir)/sbcl"` and a throwaway `HOME` under `${T}` (Portage env does not source `/etc/env.d/50sbcl`).
- Die if `.bundle-libs/setup.lisp` is missing.
- Run `scripts/setup.sh` as the compile smoke (loads bundle, compiles qlot systems). FASLs under `${T}` are discarded; first user `qlot` compiles into `~/.cache/common-lisp` (image `HOME=/home/builder` is writable). Same “sources in the package, FASLs on use” model as `common-lisp-3` libraries.
- **Do not** run `scripts/install.sh`.
- `QLOT_FETCH=curl` in setup.sh is unused when the bundle exists; do not add `net-misc/curl` solely for that.

### 4. Install prefix `/usr/share/qlot` + `/usr/bin/qlot`

- **Chosen:** `cp -a` the tree to `/usr/share/qlot`; `fperms` on `bin/qlot` and `scripts/*.sh` the trampoline needs; `dosym -r /usr/share/qlot/bin/qlot /usr/bin/qlot`.
- **Why:** tree is arch-independent Lisp + shell. FHS `/usr/share` matches emacs/vim runtime data. `/usr/libexec` on this host is helper **binaries** (cups, dbus, flatpak), not app trees. Autolith stays in `$(get_libdir)` because it **does** ship ELF `.so`, a helper, and SBCL cores — not a pattern to copy here.
- **Alternative — `common-lisp-3`:** registers qlot on every SBCL sysinit ASDF path; README forbids putting the checkout on that search path.
- **No** `qlot.asd` symlink into `/usr/share/common-lisp/systems`. `install.sh` does a systems link; README warns against global registration. Our consumer is the CLI (`--no-sysinit`). Operator REPL uses `qlot exec sbcl`. Adding the symlink later is an `-rN`.

### 5. Dependencies

- `dev-lisp/sbcl` without `[source]` (qlot does not need Gentoo SBCL contrib sources).
- `dev-libs/openssl:=` — runtime HTTPS is dexador + cl+ssl, not curl.
- `dev-vcs/git` — `qlot install` of git/github qlfile sources (materialize-time; also reasonable on a host tool install).
- **Not** Autolith `DEPEND`. Autolith emerge stays offline from `autolith-${PV}-deps.tar.xz`.

### 6. LICENSE inventory

- Map qlot `LICENSE.txt` (MIT) and each `.bundle-libs/software/*` project to Gentoo `licenses/` tokens during implement.
- Known mix includes MIT plus at least alexandria public-domain; expect more than `LICENSE="MIT"`.
- Add overlay `licenses/` entries only if Gentoo lacks a token.

### 7. KEYWORDS

```
KEYWORDS="~amd64 ~ppc ~ppc64 ~riscv ~sparc ~x86 ~x64-macos"
```

- Tilde-only (overlay policy).
- Arch set from live Gentoo `dev-lisp/sbcl` (minus `-*`, which is SBCL bootstrap-binary policy, not qlot’s).
- No `~arm64` (Gentoo SBCL not keyworded).

### 8. test USE

- `IUSE="test"`; `RESTRICT="!test? ( test )"`.
- `src_test`: `qlot --version` (assert the PV is printed) or load `.bundle-libs/setup.lisp` — not upstream Rove/Roswell CI. Upstream `--version`/`--help` call `uiop:quit -1` (shell 255) after printing; do not treat that as a test failure.
- No shell-completion USE.

### 9. Seed-and-pin

- No manager `lookupPolicy` / GitMv for qlot. Image later needs “a qlot”, not “latest qlot”; Autolith `qlfile.lock` chooses library PVs at materialize time.
- GitMv remains a documented future option if releases start breaking Autolith materialize.

### 10. Work locations

| Artifact | Repository |
|----------|------------|
| ebuild, metadata, Manifest, md5-cache | mndz-overlay |
| OpenSpec | mndz-overlay-manager |
| overlay-assets | none |

### 11. Follow-on (out of scope)

| Change | Role |
|--------|------|
| `materialize-overlay-qlot` | Image `emerge ::mndz`, drop Quicklisp fetch, PATH `qlot install`, generator bump. Propose only after this seed is applied and archived. |
| `revise-dev-util-autolith-fhs-license` | Autolith LICENSE `-r1` then FHS split `-r2`. Separate handoff. |

## Risks / Trade-offs

- **[Risk]** Release tarball for a future PV might omit `.bundle-libs` → **Mitigation:** compile dies if `setup.lisp` is missing; do not silently fetch Quicklisp. Revisit a pinned client only if that happens.
- **[Risk]** `SBCL_HOME` unset in Portage → `Can't find sbcl.core` → **Mitigation:** export in `src_compile` (image `ENV` does not leak into the ebuild sandbox).
- **[Risk]** LICENSE token mismatch vs Gentoo `licenses/` → **Mitigation:** inventory during implement; add overlay license files only if needed.
- **[Risk]** First `qlot` invocation compiles FASLs into `HOME` cache → **Mitigation:** accepted; do not install FASLs into `/usr/share`.
- **[Risk]** Operator `(asdf:load-system :qlot)` fails without systems symlink → **Mitigation:** intentional; use `qlot exec sbcl` or `-rN` later.

## Migration Plan

1. Add `dev-lisp/qlot/qlot-1.8.4.ebuild` + `metadata.xml`; `ebuild … manifest`; package `egencache`.
2. Overlay commit for the package tree.
3. Operator: `emerge -av1 =dev-lisp/qlot-1.8.4` then `qlot --version`.
4. Archive this change. Only then propose `materialize-overlay-qlot`.

## Open Questions

- Exact Gentoo `LICENSE` token list for the ~40 bundled libraries (inventory during implement; does not change layout or tasks).
