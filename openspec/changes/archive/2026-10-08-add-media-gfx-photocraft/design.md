# Design

## Context

See `proposal.md` for why `media-gfx/photocraft` is seeded at `0.1.1`. The manager already plans Cargo packages through `DepsAndAssets`, packs every registry crate in the workspace lock under `cargo_home/gentoo/`, rewrites assets `SRC_URI`, `KEYWORDS`, and `RUST_MIN_VER`, and leaves donor phases outside the `pycargoebuild` inplace region. `policyArches` with a non-empty allowlist already writes `KEYWORDS="-* ~arch"` for each allowlisted arch that has a lane target. `Update.Targets.resolveTargets` already accepts `category/package` and an unambiguous bare name. The materialize image `mndz-overlay-manager/materialize:local` already exists. Production assets live in `0x6d6e647a/mndz-overlay-assets`.

PhotoCraft is a virtual Cargo workspace: no root `[package]`, lockfile at the repository root, and `apps/photocraft` excluded from `default-members`. Upstream `packaging/linux/package.sh` builds both `photocraft` and `photocraft-cli`. Session libraries are dlopen dependencies. `rfd` compiles the portal client in; a failed portal falls back to zenity, and a user cancel does not. `crates/doc` uses `AtomicU64`, which `powerpc` and 32-bit `mips` targets do not provide.

## Goals / Non-Goals

**Goals:**

- Publish the `0.1.1` crates release with the existing Cargo packer before the policy entry exists, then let `outdated` and `update` select the newest comparable numeric tag.
- Add one `policyArches` entry and keep donor `IUSE`, phases, install layout, and the extra `LICENSE` line across rewrite.
- Keep the seed `KEYWORDS` string equal to the allowlist output so the first update does not revision-bump for keywords alone.

**Non-Goals:**

- A new planner, CLI flag, ecosystem, or image recipe. Technique vocabulary stays `DepsAndAssets`.
- Compile-time `X`, `wayland`, or `avif` switches, a Cargo.toml patch, or keywords for `ppc` and `mips`.
- Packaging wasm, fuzz crates, or `docs/brand`. Emerging PhotoCraft inside the materialize image. A native GPU smoke gate.
- Replacing the README `caddy-analyzer` package-target examples, or editing `runtime-lanes` / `project-docs`.

## Decisions

### Seed the predecessor outside `update`

`update` selects the newest comparable numeric tag. Once `v0.2.0` exists, a policy-driven `update` will not pack `v0.1.1`. Run the existing Cargo full-path packer for tag `v0.1.1` inside `mndz-overlay-manager/materialize:local`. Do not rebuild that image. Publish release `photocraft-0.1.1` / `photocraft-0.1.1-crates.tar.xz` with `b3`, `sha256`, and `sha512` sidecars and a GPG-signed assets commit. Leave an existing release tag untouched. Write the overlay ebuild from that harvest, then add the policy entry.

The ebuild inherits `cargo`, sets `CRATES=""`, and records the single harvested `RUST_MIN_VER`. `cargo.eclass` owns the Rust toolchain dependency. The primary `SRC_URI` is the `storytold/photocraft` tag archive; the crates `SRC_URI` uses `${PV}` under `0x6d6e647a/mndz-overlay-assets`.

Alternatives considered: calling `update` to create the seed (it would skip `0.1.1`); provenance `CargoCratesIo` (the product is the git workspace, and crates.io publication was not established); pinning the destination PV in the CLI (package targets never select a version).

### Point pycargoebuild at `apps/photocraft`

Add `policyArches` for `media-gfx/photocraft`: GitHub `storytold` / `photocraft` / prefix `v`, technique `DepsAndAssets (Cargo Nothing (Just "apps/photocraft") CargoGitTag)`, arches `amd64`, `x86`, `arm`, `arm64`, `ppc64`, `loong`, `riscv`, `sparc`, `s390`. Lock resolution stays at the clone root, where `Cargo.lock` lives. `pycargoebuild` runs in `apps/photocraft` because it rejects a virtual workspace root. That split is the existing `mLockSub` / `mPkgSub` behavior used by `usage` and `codex`.

`assembleKeywordsFor` needs no writer change. An empty allowlist would keyword every discovered runtime arch, including `ppc` and `mips`. The seed ebuild carries `KEYWORDS="-* ~amd64 ~x86 ~arm ~arm64 ~ppc64 ~loong ~riscv ~sparc ~s390"` so `keywordsMatch` does not demand `-r1` on the first apply. An allowlisted arch with no lane target is omitted. `~s390` is valid through `dev-lang/rust-bin`.

`ppc` stays out because `crates/doc` requires `AtomicU64` and `powerpc-unknown-linux-gnu` has no 64-bit atomics; `cargo check` of both programs failed there. `mips` stays out for the same atomic cfg, and Gentoo's `mips` keyword covers triples that also lack `target_has_atomic="64"`. `ppc64` has 64-bit atomics and stays in.

Alternatives considered: no package subdirectory (planning hard-fails on the virtual workspace); an amd64-only allowlist (cross `cargo check` succeeded on the other listed triples); clearing the allowlist (would admit `ppc` and `mips`).

### Keep backends and codecs as runtime dependencies

Declare `IUSE="+gui +cli +portal +X +wayland test"` and `REQUIRED_USE="|| ( gui cli ) gui? ( || ( X wayland ) )"`. `src_compile` passes `-p photocraft` and `-p photocraft-cli` according to `gui` and `cli`. Those `-p` arguments stay out of `ECARGO_ARGS`: `cargo_src_configure` forwards that variable to build, test, and install. `cargo install` rejects `-p`, so `src_install` runs `dobin` on `$(cargo_target_dir)/photocraft` and `$(cargo_target_dir)/photocraft-cli` for the same USE flags. `src_test` runs `cargo test --workspace --exclude photocraft-web --exclude xtask`. The inherited `cargo_src_test` would forward a package selection and drop the library crates. Web is wasm-only; fuzz crates are nested workspaces and are not members. The package license is `|| ( MIT Apache-2.0 )`. Portage treats a bare `OR` as a license name, so the Cargo expression `MIT OR Apache-2.0` is not valid `LICENSE` syntax.

`portal`, `X`, and `wayland` are `RDEPEND` conditions. The app crate hardcodes `eframe` features `wayland` and `x11`. `rfd` dlopens dbus and falls back to zenity only when the portal returns no result. `gui` always depends on dbus, `xdg-utils`, `libglvnd`, `vulkan-loader`, and `libxkbcommon`. `X` adds the X libraries and `libxkbcommon[X]`. `wayland` adds `dev-libs/wayland`. A portal backend and a Vulkan ICD stay desktop-profile packages. `USE=-portal` depends on `gnome-base/zenity` and does not pull gtk for its own sake.

Install the files `packaging/linux` installs: both binaries, the `ai.storyteller.photocraft` desktop file, mime package, hicolor icons, and metainfo with `@VERSION@` and `@DATE@` substituted. Do not install `docs/brand`.

Crate licenses stay in the `pycargoebuild` `LICENSE+=` block. Put `OFL-1.1`, `ISC`, `CC0-1.0`, and `SCOWL` in a second `LICENSE+=` after that block so inplace updates replace only the generated block. Add overlay `licenses/SCOWL`. Fonts, icons, the wordlist, and the CMYK profile are `include_bytes!` payloads, so they need no separate `SRC_URI`.

Alternatives considered: building both binaries unconditionally; compile flags for the backends (the eframe features are already on, and the `.so` files are dlopen'd); an `avif` USE flag (it is an encode-only feature of `photocraft-codecs`, not an app-crate feature, and it was declined).

### Test the policy and the donor, then smoke on the host

Extend `test/Test/Policy.hs` the way `caddy-analyzer` is covered: `lookupPolicy`, `resolveSource`, and `lookupLaneArches`, plus qualified and bare target resolution with no version pin. Add a donor-preservation fixture that rewrites a `0.1.1`-shaped ebuild to a newer PV and checks that `IUSE`, `REQUIRED_USE`, the workspace `src_test` excludes, the desktop install, and `SCOWL` outside the generated block survive, while `CRATES`, the generated license block, `RUST_MIN_VER`, `KEYWORDS`, and the assets URL may change.

Operator acceptance is separate from those tests. Emerging needs the operator's sudo password. After the seed install, `photocraft --version` and `photocraft-cli --version` must print a version and exit 0. Then `outdated` must report a newer comparable tag and `update` must apply it. The operator builds and tests that newer ebuild, including `USE=test`. A headless `--version` check is the smoke. Corpus tests skip when `corpus/` is absent, and GPU parity tests skip when no wgpu adapter is present; those skips are expected.

## Risks / Trade-offs

- [Risk] The seed `KEYWORDS` string differs from the allowlist output. → Copy the allowlist string into the seed before the first `update`, or that apply writes `-r1` for keywords alone.
- [Risk] The extra `LICENSE+=` sits inside the generated crate-license region. → Place it after the marked block and assert `SCOWL` survives a fixture rewrite.
- [Risk] A newer numeric tag appears before apply. → `update` still selects the newest comparable tag. The seed release remains the one-shot `0.1.1` publish.
- [Risk] `USE=portal` with no portal backend, or `USE=wayland -X`, leaves file dialogs or image clipboard broken at runtime. → Dialogs fall back to zenity only when the portal returns no result. On the packaged tags, clipboard stays on the X11 data path. Document that limit; do not add a USE flag for unreleased `wayland-data-control`.
- [Risk] Clearing `policyLaneArches` would keyword `ppc` and `mips`. → The policy test fails if the allowlist is empty or if either arch appears.
- [Risk] The crates tarball is about 600 registry crates. → Use the existing image and hermetic packer; do not unpack that tree into the manager repository.
- [Risk] `cargo test` skips corpus and GPU cases in this environment. → Treat those skips as acceptable. The operator `USE=test` emerge is the test run that must pass.

## Migration Plan

1. Pack and publish assets release `photocraft-0.1.1` with the existing container steps. Confirm the tag is new.
2. Add `media-gfx/photocraft/photocraft-0.1.1.ebuild`, `metadata.xml`, and `licenses/SCOWL` in the overlay. Commit with a one-line GPG-signed subject. Confirm `open` is a GUI dependency on `v0.1.1` while keeping the specified `xdg-utils` `RDEPEND`.
3. The operator emerges `0.1.1` and runs the headless version smoke.
4. Add the policy entry and the manager tests. Run `just check`.
5. Run `outdated` and `update` for `media-gfx/photocraft`. The operator emerges and tests the resulting ebuild.
6. After those gates pass, sync the delta specs into `openspec/specs/` and archive the change.

Rollback is the policy commit in this repository. The overlay seed reverts with its own commit. A published assets tag stays in place for any ebuild that already names it.
