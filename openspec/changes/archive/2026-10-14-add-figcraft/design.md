# Design

## Context

See proposal.md for why FigCraft is the missing Crafting App. The eleven apps and PhotoCraft already use one Cargo donor: `DepsAndAssets` with provenance `CargoGitTag`, lock at the repository root, package subdirectory `apps/<name>`, and `craftArches` in `src/Update/Hardcoded.hs`. The shared body is recorded in the archived change `openspec/changes/archive/2026-10-14-add-storytold-craft-apps/design.md` under "Copy the PhotoCraft body". This change adds one more package on that path.

On 2026-10-14, `storytold/figcraft` tags run `v0.2.0` through `v0.6.0`. `v0.6.0` is the newest comparable tag. `v0.5.1` is the immediate previous one. Both locks have no `git+` sources. The `v0.6.0` tree has `apps/figcraft`, `apps/figcraft-cli`, `apps/figcraft-server`, `apps/figcraft-web`, and `xtask`. It has no `crates/fonts/build.rs`. Pack day rechecks the tag list, the lock, and that build script.

## Goals / Non-Goals

**Goals:**

- Seed `media-gfx/figcraft` at the previous comparable numeric tag, then let `outdated` and `update` move it to the newest tag.
- Install `figcraft` and `figcraft-cli` with the shared USE contract. Leave `figcraft-server` uninstalled and still covered by workspace `src_test`.
- Add one `policyArches` entry that reuses `craftArches`. No new technique and no new Haskell helper.

**Non-Goals:**

- A separate package, OpenRC/systemd unit, or container for `figcraft-server`.
- ArtCraft studio, ArtCraft Launcher, ArtCraft-X, and MinecraftCraft.
- New USE flags, a font-package change, a materialize-image rebuild, or patches for the other apps' deferred `src_test` failures.

## Decisions

### Reuse the craft donor and `craftArches`

FigCraft gets the same seed-outside-`update` sequence as the eleven. On pack day, list comparable tags (prefix `v`, numeric PVs only). The seed is the immediate previous tag. Pack it in the existing `mndz-overlay-manager/materialize:local` image. Do not rebuild the image. Use `TMPDIR`, not `$HOME`. Publish assets release `figcraft-<seedPV>` with a GPG-signed assets commit before the policy entry. The ebuild inherits `cargo`, sets `CRATES=""`, records the harvested `RUST_MIN_VER`, and points the primary `SRC_URI` at the tag archive.

Policy is one `policyArches` call: GitHub `storytold` / `figcraft` / prefix `v`, `DepsAndAssets (Cargo Nothing (Just "apps/figcraft") CargoGitTag)`, arches `craftArches`. Seed `KEYWORDS` are `-* ~amd64 ~x86 ~arm ~arm64 ~ppc64 ~loong ~riscv ~sparc ~s390`. `ppc` and `mips` stay out.

The donor body is the shared contract: `IUSE="+gui +cli +portal +X +wayland test"`, the same `REQUIRED_USE`, `RESTRICT="!test? ( test )"`, `src_compile` passing `-p figcraft` and `-p figcraft-cli` outside `ECARGO_ARGS`, and `src_test` running workspace tests excluding `figcraft-web` and `xtask`. `gui` keeps the dbus, `xdg-utils`, `libglvnd`, `vulkan-loader`, and `libxkbcommon` runtime dependencies. `portal` selects `xdg-desktop-portal`; without `portal`, `gui` selects zenity. No Vulkan ICD and no portal backend. Install desktop id `ai.storyteller.figcraft`, the mime package, the hicolor tree, and metainfo with `@VERSION@` and `@DATE@` substituted. The `v0.6.0` tree ships `hicolor/scalable`, so `doicon -s scalable` applies. Do not install `docs/brand`. License is `|| ( MIT Apache-2.0 )`. The app icon is original artwork under that same license, so it adds no `LICENSE+=` term. `metadata.xml` follows the other craft apps (`maintainer-needed`). FigCraft adds no local flag.

`eframe` on the GUI crate enables `wgpu` and `accesskit` as crate features. Those stay crate features. The CLI crate depends on `figcraft-mcp`. That stays inside `figcraft-cli`. No `mcp` USE flag. FigCraft is not an audio GUI, so it does not gain `alsa-lib`. `libglvnd` and `vulkan-loader` stay behind `gui?`, the same as VectorCraft, because the CLI crate does not link `eframe`.

If the seed tag contains `crates/fonts/build.rs`, add the existing `media-fonts/craft-fonts:=` `BDEPEND` and the absolute `CRAFT_FONTS_DIR` / `CRAFT_FONTS_REQUIRED=1` exports. The newest tag does not contain that file. Do not export the variable when the script is absent.

`v0.5.1` and `v0.6.0` have no git crate sources. The ebuild does not gain `SRC_URI+=" ${CARGO_CRATE_URIS}"` unless the packed tag declares `GIT_CRATES`. The existing rewrite already inserts that line for empty `CRATES` plus `GIT_CRATES`. No new editor code.

The existing donor-preservation fixture already covers a craft-app rewrite. Extend `test/Test/Policy.hs` for this key. Do not add a second fixture.

Alternatives considered: a new technique for the server-capable workspace (rejected; the GUI and CLI are the same Cargo shape); `app-office` beside DesignCraft (rejected; the desktop and AppStream categories are Graphics, 2DGraphics, and VectorGraphics, which is `media-gfx`); exposing `wgpu` or `accesskit` as USE flags (rejected; the same decision as VectorCraft).

### Look at `figcraft-server`, then leave it uninstalled

`apps/figcraft-server` is a headless native collaboration server. Its crate description is a standalone process that keeps many files behind share links, persists snapshots plus a log, and serves live sessions. `packaging/server` ships a systemd unit, a backup timer, nginx and Caddy samples, and a container build. That is a network service with its own install path, not a second desktop binary.

`src_compile` and `src_install` select only `figcraft` and `figcraft-cli`. The ebuild does not `dobin` `figcraft-server` and does not install the unit files. `src_test` still runs the workspace, so the server crate's tests run. The phase does not exclude `figcraft-server` and does not pass `-p`.

Alternatives considered: installing the server binary and the systemd unit (a different package shape, and the operator chose the GUI and CLI only); excluding `figcraft-server` from `src_test` (would hide the crate and break the workspace-test rule).

### Operator smoke stays outside the agent

The agent does not run `sudo`. It hands one emerge at a time. Seed smoke is `figcraft --version` and `figcraft-cli --version`, each printing a version and exiting 0. After the policy entry, `outdated` for `media-gfx/figcraft` and bare `figcraft` reports the same move from the seed PV to the newest comparable tag. `update` publishes `figcraft-<newPV>` without overwriting the seed release. The operator then emerges that ebuild with `USE=test` and `FEATURES=test`.

Overlay commits stay one-line subjects `media-gfx/figcraft: <PV>`, GPG-signed, empty body. The assets commit is GPG-signed and lands before the policy entry. The manager commit is a Conventional Commit and may include this package only after the seed assets release exists.

## Risks / Trade-offs

- [Risk] A newer tag appears between this survey and pack day. → Resolve the previous comparable tag that day. `update` selects whatever is newest at smoke time. The seed release stays published.
- [Risk] The seed tag grows `crates/fonts/build.rs` or a `GIT_CRATES` map. → Recheck both on pack day. Add the font export only when the script exists. Let the existing fetch-line rewrite insert `CARGO_CRATE_URIS` only when `GIT_CRATES` is declared.
- [Risk] Workspace `src_test` fails on this host, including the server crate or `apps/figcraft-cli/tests/fonts.rs`. → Keep the tests in `src_test`. Do not skip or patch them in the seed. The operator decides after the failure is logged, the same way the four deferred apps were handled. On 2026-10-14 the `USE=test` emerge of 0.6.0 failed in `figcraft-ui-egui` (three assertions). `figcraft-server` had already passed. The operator chose to leave the assertions and the ebuild unchanged. The log is in `tasks.md`. Task 4.1 is closed as deferred.
- [Risk] `hicolor/scalable` disappears on the seed tag. → Install the sizes that tag ships. Do not require a scalable directory when it is absent.
- [Risk] Two crate tarballs (seed and update) fill `TMPDIR`. → Pack one PV at a time. Do not pack under `$HOME`.

## Migration Plan

1. Resolve the seed tag, pack and publish `figcraft-<seedPV>`, write the donor ebuild, Manifest, and md5-cache, and create the overlay commit. The operator emerges the seed.
2. Add the policy entry and the policy tests. Run `outdated`, then `update`. The operator emerges the newer ebuild with `USE=test` and `FEATURES=test`.
3. A pack or emerge failure stops this package. It does not change the other craft apps.

Rollback is to leave the policy entry uncommitted until the seed assets release exists, and to leave the newer ebuild unpublished if `update` fails. The seed assets release, once published, stays.

## Open Questions

None. The server stays out of `src_install`, and the category is `media-gfx`.
