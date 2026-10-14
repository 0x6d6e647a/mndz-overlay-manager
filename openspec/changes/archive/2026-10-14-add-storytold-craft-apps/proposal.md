# Proposal

## Why

Eleven Storytold craft apps have no mndz-overlay ebuild and no manager policy, so `outdated` and `update` cannot follow their releases. PhotoCraft already proved the virtual-workspace Cargo path. The apps also embed an optional font checkout from `storytold/craft-fonts`, which has no Gentoo package and no numeric tags for the manager to follow.

## What Changes

- Add eleven overlay packages, each seeded at the previous comparable numeric Git tag resolved on the day that seed is packed. Publish that seed's crates release with the existing materialize-container steps before the package's policy entry exists. `update` selects the newest comparable tag and will not materialize the older seed once a newer tag exists.
- Track each app as `DepsAndAssets` Cargo, provenance `CargoGitTag`, tag prefix `v`, lock at the repository root, package subdirectory `apps/<name>`, runtime-lane arches `amd64`, `x86`, `arm`, `arm64`, `ppc64`, `loong`, `riscv`, `sparc`, and `s390`. The seed `KEYWORDS` string matches that allowlist so the first update does not revision-bump for keywords alone.
- Share PhotoCraft's USE and session contract (`+gui +cli +portal +X +wayland test`). Add per-app flags: LightCraft `+heif` and `rawnind-model` (default off); FilmCraft `whisper`, `neural-voices`, `vaapi`, and `nvenc` (all default off); PdfCraft `cups` (default off). EffectCraft gets `whisper`, `neural-voices`, `vaapi`, and `nvenc` only when that seed's app crate exposes them. Preserve each donor body across the Cargo rewrite.
- Add `media-fonts/craft-fonts` at PV `0.0.0`, installing the `main` commit resolved on pack day to `/usr/share/craft-fonts`. Consumers that embed fonts `BDEPEND` on it with a subslot operator. Policy is `Unsupported` because the repository publishes no comparable numeric tag; `update` soft-skips it. A later `GitMvAndManifest` flip waits until a `v*` tag exists. `0.0.0` compares less than `0.1.0`.
- After each app's policy exists, `outdated` reports a newer comparable tag and `update` applies it. The operator emerges the seed and the updated build. EffectCraft (`GIT_CRATES` on a filmcraft revision) and PdfCraft (path `vendor/` plus `aws-lc-sys`) are named spikes; a pack failure on one does not stop the others.

## Capabilities

### New Capabilities

- `storytold-craft-apps`: identity, USE, dependencies, install layout, licenses, predecessor crates releases, and headless version smoke for the eleven apps.
- `media-fonts-craft-fonts`: the shared font checkout, its pre-tag snapshot ebuild, and the `Unsupported` policy.

### Modified Capabilities

- `update-source`: GitHub sources for the eleven apps and `media-fonts/craft-fonts`.
- `update-apply`: canonical policy entries, Cargo package subdirectories, the shared runtime-lane allowlist, and the font package's `Unsupported` technique.
- `cargo-crates-assets`: hardcoded Cargo policy for the eleven apps, and donor-body preservation across rewrite.
- `overlay-test-use`: `IUSE=test` and workspace `src_test` excludes for the eleven apps.

## Impact

- Manager: twelve policy entries and package-focused tests. Cargo materialize, `GIT_CRATES` filtering, KEYWORDS assembly, and signed commits stay on the existing path. No new CLI flag, config key, or ecosystem.
- Overlay: eleven app ebuilds plus `metadata.xml`, and `media-fonts/craft-fonts`. `media-fonts` and the app categories already exist in the Gentoo tree. No `profiles/categories` file.
- Assets: one `{pn}-{seedPV}` crates release per app, then the newer PV from `update`. `craft-fonts` publishes no crates release.
- Operator smoke is `<name> --version` and `<name>-cli --version`. Emerge needs the operator's sudo password and runs one package at a time. None of these packages is a materialize-image dependency or an overlay wait-edge provider.
- README, CONTRIBUTING, and AGENTS stay unchanged. The CLI, config, and quality pipeline are unchanged.

## Non-goals

- PhotoCraft. A later session runs `update`, then a `-r1`, for body edits such as `+heif`.
- A CLI version pin, a follow-main technique, or a planner that can be asked to materialize a non-newest tag.
- Switching `media-fonts/craft-fonts` to `GitMvAndManifest` before a comparable numeric tag exists. Tagging `storytold/craft-fonts` ourselves.
- `avif`, `mcp`, `jack`, `pipewire`, `wgpu`, `accessibility`, `denoise`, `dhat`, or `windows7` USE flags. `ppc` or `mips` keywords. Patching `AtomicU64`.
- Vendoring the RawNIND weights, or putting `GPL-3` on LightCraft's `LICENSE` for the downloader flag.
- Installing `docs/brand`, registering the fonts with fontconfig, packaging wasm, xtask, or fuzz crates, or emerging any of these packages inside the materialize image.
- Rebuilding `mndz-overlay-manager/materialize:local`. Replacing the README package-target examples.
