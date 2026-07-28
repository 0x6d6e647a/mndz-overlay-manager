## Context

Autolith (`github.com/luciusmagn/autolith`) is a terminal Common Lisp agent that pins SBCL via `sbcl.version` (2.6.4 on v0.17.2 and v0.18.0), locks Lisp deps with qlot (`qlfile` / `qlfile.lock`), builds private natives (fff via Cargo, ColorLisp tree-sitter, cl-exec-sandbox helper), and boots recovery/active SBCL cores. Upstream packaging is Nix and a Linux x86_64 binary release; there is no Gentoo package.

mndz-overlay has no Lisp/SBCL application pattern yet. Manager ecosystems today are Go / Npm / Bun / Cargo under `DepsAndAssets`; an SBCL ecosystem is deferred to `support-dev-util-autolith`. This seed is **manual** overlay + assets work; OpenSpec lives only in mndz-overlay-manager.

Author clarification (Lukáš Hozda): exact pin exists so build runtime, run runtime, and SBCL sources match for debug spans/hotpatch. Floor ≥ `sbcl.version` is fine if identity is stamped at build; Portage may use Gentoo SBCL ≥ 2.6.4 (2.6.5/2.6.6 testing) without overlay SBCL.

Local investigation clone: `/home/mndz/repos/com.github/luciusmagn/autolith`. Host multiarch probe prep: `~/mndz-overlay-manager-docker-setup.md`.

## Goals / Non-Goals

**Goals:**

- Ship a working `=dev-util/autolith-0.17.2` that emerges offline (for Autolith deps) and runs `autolith --version`.
- Publish a single deps asset with `.qlot/` + vendored fff for offline `src_compile`.
- Encode SBCL floor, identity stamping, private prefix, test USE, and KEYWORDS so later manager updates can treat the ebuild as a template.
- Provide `autolith-make-deps-tarball.py` for seed asset creation (Haskell materialize later).

**Non-Goals:**

- Manager policy, SBCL runtime lanes, or apply materialize in this change.
- PV newer than 0.17.2.
- Multiarch Docker probe execution (follow-on change).
- Overlay-packaged SBCL; arm64 KEYWORDS; shell completions; full upstream `script/check`.

## Decisions

### 1. Package identity

- **Category/PN:** `dev-util/autolith` (agent tools shelf).
- **PV:** `0.17.2` from tag `v0.17.2` (not 0.18.0) so support-phase manager update is a real bump.
- **Ebuild filename:** `autolith-0.17.2.ebuild` (no `-r0`; only `-r1+` if content-only fixes).
- **DESCRIPTION:** `Live, self-modifying Common Lisp AI agent`
- **HOMEPAGE:** `https://github.com/luciusmagn/autolith`
- **LICENSE:** `ISC` (Gentoo `licenses/ISC` already exists; Autolith LICENSE text is ISC).
- **metadata.xml:** GitHub remote-id `luciusmagn/autolith`.

### 2. Deps assets (single tarball)

- Distfile: `autolith-0.17.2-deps.tar.xz` (pattern `{pn}-{pv}-deps.tar.xz`).
- Release tag: `autolith-0.17.2`.
- Sidecars under `dev-util/autolith/` in mndz-overlay-assets; commit message `dev-util/autolith: 0.17.2`.
- **Layout inside tarball:**

  ```text
  .qlot/     # full tree after qlot install against qlfile.lock
  fff/       # checkout of native/fff/commit + Cargo.lock + vendor/ from cargo vendor
  ```

- Helper: `mndz-overlay/autolith-make-deps-tarball.py` (network allowed **only** when building the asset on a developer/manager host; Portage never runs it).
- Ebuild `SRC_URI`: GitHub archive `v${PV}` + parameterized assets URL for deps tarball.

### 3. SBCL floor and identity (Gentoo only)

- **RDEPEND/BDEPEND:** `>=dev-lisp/sbcl-2.6.4:=[source]` (subslot rebuild when SBCL PV changes).
- Upstream `sbcl.version` is the **floor**; refuse emerge if installed SBCL is older.
- At build: capture `lisp-implementation-version`; write installed tree’s `sbcl.version` to that exact PV (author: build ≡ run ≡ sources).
- **Synthetic** `AUTOLITH_SBCL_SOURCE_ROOT` under private prefix: `version.lisp-expr` containing `"${SBCL_PV}"` plus `src` → Gentoo `/usr/$(get_libdir)/sbcl/src` (USE=source). Fall back to unpacking full matching SBCL source tarball into private prefix if synthetic layout fails smoke.
- Do **not** use upstream `sbcl-source.sha256` as Portage identity for non-2.6.4 installs.
- Wrapper exports `AUTOLITH_SBCL` (system sbcl) and `AUTOLITH_SBCL_SOURCE_ROOT`.

### 4. Disable network install paths

- Package must never curl/download SBCL at runtime.
- Prefer: thin `/usr/bin/autolith` wrapper + patch or replace `bin/autolith-runtime` download/install branches to die with a clear message.
- Build cores with direct `sbcl --script script/build-*.lisp` under controlled env (Nix-style), **not** `script/bootstrap` (network/qlot).
- Do not install `script/install` as a user entrypoint (or leave non-executable under docs only).

### 5. Private install layout

- App tree under e.g. `/usr/lib/autolith/` (source, `.qlot`, natives, cores, synthetic SBCL source root)—not `common-lisp-3` global registry.
- Fabricate a minimal **git** repo in the Autolith source tree during compile (like Nix) so recovery image provenance scripts that call `git hash-object` / `status` succeed.
- **Cores:** prefer C lean A—emerge-time cores under private prefix with `AUTOLITH_RECOVERY_CORE` / `AUTOLITH_ACTIVE_CORE` set by wrapper; fallback pure A (system cores only) if dual-path is unworkable.

### 6. Natives and offline cargo

- fff: `cargo build --offline --locked --release -p fff-c` using vendored crate tree from deps tarball; install `libfff_c.so` and set `AUTOLITH_FFF_LIBRARY`.
- ColorLisp native + cl-exec-sandbox helper: build from `.qlot` checkouts; set `COLORLISP_NATIVE_LIBRARY` and `CL_EXEC_SANDBOX_HELPER` / `CL_EXEC_SANDBOX_BWRAP`.
- BDEPEND: `virtual/rust` (or equivalent cargo provider), C toolchain, git; RDEPEND: bubblewrap, openssl, git, sbcl as above.

### 7. KEYWORDS

```bash
KEYWORDS="~amd64 ~ppc ~ppc64 ~riscv ~x86"
```

- Tilde-only (mndz-overlay practice).
- Intersect Gentoo SBCL arches for PVs ≥ 2.6.4 with arches that have `sys-apps/bubblewrap`.
- **Exclude** `~sparc`, `~x64-macos` (no bwrap); **exclude** `~arm64` (Gentoo SBCL not keyworded—upstream SBCL supports ARM; packaging gap only).

### 8. test USE

- `IUSE="test"`; `RESTRICT="!test? ( test )"`.
- `src_test`: minimal offline check (load system / assert version)—not full `script/check`.
- No bash/zsh/fish completion USE (upstream has in-TUI completion only).

### 9. Work locations

| Artifact | Repository |
|----------|------------|
| ebuild, metadata, Manifest, helper `.py` | mndz-overlay |
| deps tarball release + sidecars | mndz-overlay-assets |
| OpenSpec only | mndz-overlay-manager |

### 10. Follow-on changes (out of scope here)

| Change | Role |
|--------|------|
| `probe-autolith-multiarch` | Full emerge under QEMU: riscv64 + ppc64le (`~/mndz-overlay-manager-docker-setup.md`) |
| `support-dev-util-autolith` | Manager `DepsAndAssets` SBCL ecosystem, policy, materialize in Haskell, bump 0.17.2→0.18.0 |

## Risks / Trade-offs

- **[Risk]** Synthetic SBCL source root may not satisfy sbcl-workers path layout → **Mitigation:** smoke `self`/source paths if feasible; fall back to full private source unpack.
- **[Risk]** Recovery/active core build needs git identity → **Mitigation:** fabricate git repo in `${S}` like Nix.
- **[Risk]** Emerge-time cores as root / long compile → **Mitigation:** C lean A; document; subslot rebuild on SBCL upgrade.
- **[Risk]** Multiarch natives fail on riscv/ppc64 → **Mitigation:** probe change after seed; KEYWORDS already declare those arches.
- **[Risk]** Deps tarball large → **Mitigation:** accepted; single asset simplifies SRC_URI and later manager.
- **[Risk]** Template body must survive future manager rewrites → **Mitigation:** support change preserves non-assets lines / `src_*` (document contract in ebuild comments).

## Migration Plan

1. Implement `autolith-make-deps-tarball.py`; build and publish deps asset for 0.17.2.
2. Add ebuild + metadata; `ebuild … manifest`; commit overlay; regenerate md5-cache if required.
3. Operator: `emerge -av1 =dev-util/autolith-0.17.2` then `autolith --version`.
4. Proceed to multiarch probe, then support/manager, when smoke passes.

## Open Questions

- Whether pure emerge-time cores (A) are required immediately if C lean A is blocked by launcher assumptions—decide during implement; prefer C lean A.
- Exact private prefix path spelling (`/usr/lib/autolith` vs libdir-qualified)—prefer `$(get_libdir)`-aware path.
