# Proposal

## Why

The Crafting Apps page now lists thirteen apps. The overlay ships the other twelve. FigCraft, the interface-design app, has numeric `v` tags, Linux installers, and the same Cargo workspace shape, and `outdated` / `update` cannot follow it until it has an ebuild and a policy entry.

## What Changes

- Add `media-gfx/figcraft`, seeded at the immediate previous comparable numeric Git tag resolved on pack day. Publish that seed's crates release with the existing materialize-container steps before the policy entry exists. `update` selects the newest comparable tag and will not materialize the older seed once a newer tag exists.
- Track it as `DepsAndAssets` Cargo, provenance `CargoGitTag`, tag prefix `v`, lock at the repository root, package subdirectory `apps/figcraft`, runtime-lane arches `amd64`, `x86`, `arm`, `arm64`, `ppc64`, `loong`, `riscv`, `sparc`, and `s390`. The seed `KEYWORDS` string matches that allowlist.
- Share the existing craft-app USE and session contract (`+gui +cli +portal +X +wayland test`). Install the GUI and CLI only. Preserve the donor body across the Cargo rewrite. No per-app USE flag.
- Category is `media-gfx` because the upstream desktop and AppStream metadata are Graphics / 2DGraphics / VectorGraphics, the same bucket as VectorCraft.

## Capabilities

### New Capabilities

### Modified Capabilities

- `storytold-craft-apps`: the inventory grows from eleven apps to twelve by adding `media-gfx/figcraft`. FigCraft uses the shared USE, dependency, compile, install, and smoke requirements. It does not install `figcraft-server`.
- `update-source`: GitHub source `storytold/figcraft`, tag prefix `v`.
- `update-apply`: canonical policy entry for `media-gfx/figcraft` on the Cargo path, with the shared runtime-lane allowlist, and the same rule that a package target does not select a version.
- `cargo-crates-assets`: hardcoded Cargo policy for `media-gfx/figcraft`. Donor-body preservation already applies to every Storytold craft app.

## Impact

- Manager: one policy entry and package-focused tests. Cargo materialize, KEYWORDS assembly, and signed commits stay on the existing path. No new CLI flag, config key, or ecosystem.
- Overlay: `media-gfx/figcraft` ebuild plus `metadata.xml`. `media-gfx` already exists. No `profiles/categories` file.
- Assets: one `figcraft-<seedPV>` crates release, then the newer PV from `update`.
- Operator smoke is `figcraft --version` and `figcraft-cli --version`. Emerge needs the operator's sudo password. FigCraft is not a materialize-image dependency or an overlay wait-edge provider.
- README, CONTRIBUTING, and AGENTS stay unchanged. The CLI, config, and quality pipeline are unchanged.
- `overlay-test-use` already requires every Storytold craft app to gate workspace tests and to exclude only `<name>-web` and `xtask`. FigCraft joins that set through the inventory. No separate test-spec delta.

## Non-goals

- ArtCraft studio (`storytold/artcraft`), ArtCraft Launcher, ArtCraft-X, and MinecraftCraft.
- Packaging `figcraft-server` as an installed daemon, systemd unit, nginx site, or container. Packaging `figcraft-web`, xtask, plugins, or `docs/brand`.
- A CLI version pin, or a planner that can be asked to materialize a non-newest tag.
- `avif`, `mcp`, `jack`, `pipewire`, `wgpu`, `accessibility`, `denoise`, `dhat`, or `windows7` USE flags. `ppc` or `mips` keywords. `eframe`'s always-on `wgpu` and `accesskit` crate features stay crate features.
- Changing `media-fonts/craft-fonts`. FigCraft has no `crates/fonts/build.rs` at the tags inspected on 2026-10-14, so it does not gain `CRAFT_FONTS_DIR`.
- Rebuilding `mndz-overlay-manager/materialize:local`. Patching the deferred src_test failures of the other craft apps.
