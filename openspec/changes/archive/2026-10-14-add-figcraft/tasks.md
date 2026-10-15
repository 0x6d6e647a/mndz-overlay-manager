# Tasks

## 1. Seed ebuild

- [x] 1.1 On pack day, list comparable numeric tags of `storytold/figcraft` and take the immediate previous tag as the seed. Confirm assets tag `figcraft-<seedPV>` is absent. In the existing `mndz-overlay-manager/materialize:local` image, pack `figcraft-<seedPV>-crates.tar.xz` with the PhotoCraft `pycargoebuild` arguments (lock at the repo root, package directory `apps/figcraft`, prefix `cargo_home/gentoo`) and the hermetic tar/xz rules, plus `b3`, `sha256`, and `sha512` sidecars. Do not rebuild the image. Use `TMPDIR`, not `$HOME`. Publish that assets release with a GPG-signed assets commit before any figcraft policy entry. Write `media-gfx/figcraft/figcraft-<seedPV>.ebuild` and `metadata.xml` to the shared donor contract in `design.md`. Recheck the seed tree for `crates/fonts/build.rs` and for a `GIT_CRATES` declaration. Add the craft-fonts `BDEPEND` and absolute exports only when that build script exists. Do not add a `LICENSE+=` term for the app icon. `src_compile` and `src_install` select `figcraft` and `figcraft-cli` only. `src_test` excludes `figcraft-web` and `xtask` and does not exclude `figcraft-server`. Install the hicolor sizes the tag ships, including scalable when `hicolor/scalable` exists. Set `KEYWORDS="-* ~amd64 ~x86 ~arm ~arm64 ~ppc64 ~loong ~riscv ~sparc ~s390"`, `CRATES=""`, and the harvested `RUST_MIN_VER`. `IUSE` is `+gui +cli +portal +X +wayland test` with no `wgpu`, `accessibility`, or `mcp` flag. Regenerate Manifest and md5-cache, then create the one-line GPG-signed overlay commit `media-gfx/figcraft: <seedPV>`. Verify the assets URL downloads, the tarball members use `cargo_home/gentoo/`, the ebuild contains the KEYWORDS string, shared `IUSE`, empty `CRATES`, both `-p` arguments outside `ECARGO_ARGS`, no `figcraft-server` install, no `docs/brand` install, and no `CRAFT_FONTS_DIR` unless the font build script exists, and `git log -1` shows that subject and a signature.

## 2. Operator seed smoke

- [x] 2.1 Ask the operator to `emerge` `=media-gfx/figcraft-<seedPV>` with default USE. Verify `figcraft --version` and `figcraft-cli --version` each print a version and exit 0 without a display, and that `figcraft-server` is not installed. This task waits on the operator. Do not run sudo. One emerge at a time. Seed emerge of `=media-gfx/figcraft-0.5.1` completed in 8m16s with USE `X cli gui portal wayland -debug -test`. `FigCraft 0.5.1` and `figcraft-cli 0.5.1` each exited 0. The ebuild does not install `figcraft-server`.

## 3. Policy

- [x] 3.1 Add `policyArches` for `media-gfx/figcraft`: GitHub `storytold` / `figcraft` / prefix `v`, `DepsAndAssets (Cargo Nothing (Just "apps/figcraft") CargoGitTag)`, arches `craftArches`. Extend `test/Test/Policy.hs` for `lookupPolicy`, `resolveSource`, `lookupLaneArches`, and qualified plus bare resolution with no version pin. Verify those assertions pass and that `ppc` and `mips` are absent. Start only after assets release `figcraft-<seedPV>` exists. Do not add a second donor-preservation fixture.

## 4. Update smoke

- [x] 4.1 Run `outdated` for `media-gfx/figcraft` and bare `figcraft`. Verify both report the same move from the seed PV to the newest comparable numeric tag and that neither command accepts a version pin. Run `update` for `media-gfx/figcraft`. Verify it publishes `figcraft-<newPV>` without overwriting the seed release, keeps the donor body, writes the allowlist `KEYWORDS` string, still does not install `figcraft-server`, regenerates Manifest and md5-cache, and creates the signed overlay commit. Ask the operator to emerge that ebuild with `USE=test` and `FEATURES=test`. Verify the build and `src_test` succeed and both binaries still answer `--version` with exit 0. If `src_test` fails, stop and log the failure. Do not patch the upstream test in this change. Closed 2026-10-14 as deferred: `src_test` did not pass. The failure and the decision to leave the three assertions unchanged are in "Logged src_test failure" below. The ebuild is unchanged.

## 5. Integration gates

- [x] 5.1 Run `openspec validate add-figcraft --type change --strict` and verify it exits 0.
- [x] 5.2 Run `just check` and verify the full `hk check` gate exits 0. Confirm README, CONTRIBUTING, and AGENTS are unchanged. `just check` exited 0 on 2026-10-14 (ormolu, release build, coverage, hlint, stan 79 modules / 0 observations, weeder). README, CONTRIBUTING, and AGENTS are unchanged.

## Logged src_test failure

On 2026-10-14 the operator closed task 4.1 without a passing `src_test`. The package stays installed with `test` off and `RESTRICT` containing `test`. The ebuild still runs the workspace tests when `USE=test` and `FEATURES=test` are set. This change does not patch the three assertions. `USE=test FEATURES=test emerge =media-gfx/figcraft-0.6.0` failed in `src_test` on 2026-10-14. `cargo_src_test` ran `--workspace --exclude figcraft-web --exclude xtask`. rustc was `/opt/rust-bin-1.97.1/bin/rustc`, release, `debug-assertions=off`, `opt-level=3`, `target-cpu=tigerlake`. Suites that finished before `figcraft-ui-egui` passed, including `figcraft-server` (71 tests, then an empty binary). `figcraft-ui-egui` ran 301 passed, 3 failed, 1 ignored, in 2.56s. Cargo stopped on that crate. The installed package is still `media-gfx/figcraft-0.6.0` with USE `X cli gui portal wayland`, `RESTRICT` `test`, and `FEATURES` without `test`. `FigCraft 0.6.0` and `figcraft-cli 0.6.0` still exit 0. `figcraft-server` is not installed. Log: `/var/tmp/portage/media-gfx/figcraft-0.6.0-2026-10-14T21:13:06-07:00/temp/build.log`.

### home_tests::a_first_run_offers_templates_on_recents_and_recent_files_replace_them

Panicked at `crates/ui-egui/src/home_tests.rs:220`. The assertion is `has_text(&s, "Recent files") && has_text(&s, "ridgeline")` after `recent_files` is set to `/tmp/ridgeline.figcraft`. `has_text` requires an exact galley string. The card name is the file stem `ridgeline`. The heading is painted when `recent_files` is non-empty. The panic is one compound assertion, so the log does not say which string was absent. The asserts above line 220 in the same test passed.

### plugin_panel_tests::a_colour_field_opens_the_colour_picker_and_two_panels_show_side_by_side

Panicked at `crates/ui-egui/src/plugin_panel_tests.rs:104`. Expected `PickerTarget::PluginField { plugin: "org.test.panel", control: "accent", pending: None }`. Observed `PickerTarget::PageBackground`. The test clicks the first AccessKit node labeled `Color`. `widgets::swatch` labels every swatch `Color`, and the page-background swatch is the click that sets `PageBackground`.

### vector_tail_ui_tests::a_width_point_shows_its_sides

Panicked at `crates/ui-egui/src/vector_tail_ui_tests.rs:90`. Left side width `4` and right side width `10` matched. The `Width` spin button read `100`; the test expects `14`. `value()` returns the first spin button labeled `Width`. The width-point panel draws left, right, and `Width` from one point, and the two sides sum to `scale × stroke weight`, which is 14. The value `100` is a different spin button. The vector's second point is at x `100`.

Decision: option A, leave the three assertions and the 0.6.0 ebuild unchanged. Options not taken: B, wait for an upstream tag and re-emerge with `USE=test`; C, patch the ebuild in this change.

## Workflow follow-up

- Synced on 2026-10-14 into `openspec/specs/`, then archived. The living `storytold-craft-apps` Purpose still says twelve apps. Scenario "Eleven apps are present" is unchanged. Added requirements: "FigCraft joins the craft inventory" and "FigCraft omits the collaboration server". Modified requirements "Hardcoded source overrides", "Hardcoded policy covers known overlay packages", and "Hardcoded cargo packages enabled" insert `media-gfx/figcraft` and keep their previous scenarios. Living specs contain no change-delta residue.
- `openspec validate --specs --strict` after the sync: 10 passed, 48 failed (58 items). The totals match the pre-sync result. `storytold-craft-apps` passes, including the two new requirements. The 48 failures are the same pre-existing requirement-length warnings.
