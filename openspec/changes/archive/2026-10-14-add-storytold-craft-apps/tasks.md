# Tasks

## 1. Shared font package

- [x] 1.1 Resolve `main` of `storytold/craft-fonts` on pack day and record the full commit. Add `media-fonts/craft-fonts/craft-fonts-0.0.0.ebuild` and `metadata.xml` whose `SRC_URI` is that commit archive, `LICENSE="OFL-1.1"`, `SLOT="0/${PV}"`, and `KEYWORDS="-* ~amd64 ~x86 ~arm ~arm64 ~ppc64 ~loong ~riscv ~sparc ~s390"`. Install `fonts/manifest.txt` and the family directories under `/usr/share/craft-fonts/fonts/`. Do not install the Rust crate, a fontconfig file, or an assets URI. Regenerate Manifest and package-scoped md5-cache, then create the one-line GPG-signed overlay commit `media-fonts/craft-fonts: 0.0.0`. Verify `git log -1` shows that subject and a signature, `SRC_URI` contains the full sha, and the ebuild has no `refs/tags/` or `mndz-overlay-assets` entry.
- [x] 1.2 Ask the operator to `emerge` `=media-fonts/craft-fonts-0.0.0`. Verify `/usr/share/craft-fonts/fonts/manifest.txt` exists and each family directory named by that manifest is installed. This task waits on the operator because emerge needs their sudo password. Do not run sudo.
- [x] 1.3 Add an `Unsupported` policy entry for `media-fonts/craft-fonts`: GitHub `storytold` / `craft-fonts` / prefix `v`, reason that `storytold/craft-fonts` publishes no comparable numeric tag. Extend `test/Test/Policy.hs` for `lookupPolicy`, `resolveSource`, and bare-name resolution. Verify those assertions pass, `update` planning soft-skips this key with a reason that names the unsupported technique, and no assets publish is required.

## 2. Donor-preservation fixture

- [x] 2.1 Add a fixture that rewrites a craft-app donor to a newer PV. The donor declares `IUSE` including `+heif` and `rawnind-model`, `cups`, and `whisper`, `REQUIRED_USE="|| ( gui cli ) gui? ( || ( X wayland ) )"`, workspace `src_test` excludes for `<name>-web` and `xtask`, a desktop install, a `LICENSE+=` term outside the generated block, and `export CRAFT_FONTS_DIR=/usr/share/craft-fonts`. Verify the new test passes, those donor lines remain, and the fixture still allows `CRATES`, the generated license block, `RUST_MIN_VER`, `KEYWORDS`, and the assets `SRC_URI` to change.

## 3. app-office/gridcraft

- [x] 3.1 On pack day, list comparable numeric tags of `storytold/gridcraft` and take the immediate previous tag as the seed. Confirm assets tag `gridcraft-<seedPV>` is absent. In the existing `mndz-overlay-manager/materialize:local` image, pack `gridcraft-<seedPV>-crates.tar.xz` with the PhotoCraft `pycargoebuild` arguments (lock at the repo root, package directory `apps/gridcraft`, prefix `cargo_home/gentoo`) and the hermetic tar/xz rules, plus `b3`, `sha256`, and `sha512` sidecars. Do not rebuild the image. Use `TMPDIR`, not `$HOME`. Publish that assets release with a GPG-signed assets commit before any gridcraft policy entry. Write `app-office/gridcraft/gridcraft-<seedPV>.ebuild` and `metadata.xml` to the shared donor contract in `design.md`. If the seed tag contains `crates/fonts/build.rs`, add `BDEPEND="media-fonts/craft-fonts:="` and the absolute `CRAFT_FONTS_DIR` / `CRAFT_FONTS_REQUIRED=1` exports. Set `KEYWORDS="-* ~amd64 ~x86 ~arm ~arm64 ~ppc64 ~loong ~riscv ~sparc ~s390"`, `CRATES=""`, and the harvested `RUST_MIN_VER`. Regenerate Manifest and md5-cache, then create the one-line GPG-signed overlay commit `app-office/gridcraft: <seedPV>`. Verify the assets URL downloads, the tarball members use `cargo_home/gentoo/`, the ebuild contains the KEYWORDS string, shared `IUSE`, empty `CRATES`, both `-p` arguments outside `ECARGO_ARGS`, and no `docs/brand` install, and `git log -1` shows that subject and a signature.
- [x] 3.2 Ask the operator to `emerge` `=app-office/gridcraft-<seedPV>` with default USE. Verify `gridcraft --version` and `gridcraft-cli --version` each print a version and exit 0 without a display. This task waits on the operator. Do not run sudo. One emerge at a time.
- [x] 3.3 Add `policyArches` for `app-office/gridcraft`: GitHub `storytold` / `gridcraft` / prefix `v`, `DepsAndAssets (Cargo Nothing (Just "apps/gridcraft") CargoGitTag)`, arches `amd64`, `x86`, `arm`, `arm64`, `ppc64`, `loong`, `riscv`, `sparc`, `s390`. Extend `test/Test/Policy.hs` for `lookupPolicy`, `resolveSource`, `lookupLaneArches`, and qualified plus bare resolution with no version pin. Verify those assertions pass and that `ppc` and `mips` are absent. Start only after assets release `gridcraft-<seedPV>` exists.
- [x] 3.4 Run `outdated` for `app-office/gridcraft` and bare `gridcraft`. Verify both report the same move from the seed PV to the newest comparable numeric tag and that neither command accepts a version pin. Run `update` for `app-office/gridcraft`. Verify it publishes `gridcraft-<newPV>` without overwriting the seed release, keeps the donor body from task 2.1, writes the allowlist `KEYWORDS` string, regenerates Manifest and md5-cache, and creates the signed overlay commit. Ask the operator to emerge that ebuild with `USE=test` and `FEATURES=test`. Verify the build and `src_test` succeed and both binaries still answer `--version` with exit 0.

## 4. app-office/wordcraft

- [x] 4.1 Repeat task 3.1 for `app-office/wordcraft` (`storytold/wordcraft`, `apps/wordcraft`). Extra `LICENSE+=` terms cover installed or embedded OFL fonts and the Moby / CC0 hyphenation data. Do not add `SCOWL`. Verify the same artifacts as task 3.1 and that `LICENSE` names `OFL-1.1` outside the generated block and does not name `SCOWL`.
- [x] 4.2 Repeat task 3.2 for `=app-office/wordcraft-<seedPV>` and binaries `wordcraft` and `wordcraft-cli`.
- [x] 4.3 Repeat task 3.3 for `app-office/wordcraft` with package subdirectory `apps/wordcraft`. Verify the new policy assertions pass.
- [x] 4.4 Repeat task 3.4 for `app-office/wordcraft` and bare `wordcraft`. `USE=test FEATURES=test` emerge of 0.6.1 completed on 2026-10-12. VDB `USE` and `FEATURES` include `test`, `RESTRICT` is empty, and `DEFINED_PHASES` includes `test`. `wordcraft 0.6.1 (dev)` and `wordcraft-cli 0.6.1` each exited 0.

## 5. app-office/designcraft

- [x] 5.1 Repeat task 3.1 for `app-office/designcraft` (`storytold/designcraft`, `apps/designcraft`). A missing `crates/testkit` directory is not by itself a failure when locked metadata for `apps/designcraft` succeeds. If the pack fails, record the error, leave tasks 5.2–5.4 unchecked, and continue at task 6. Verify the same artifacts as task 3.1 when the pack succeeds.
- [x] 5.2 Repeat task 3.2 for `=app-office/designcraft-<seedPV>` and binaries `designcraft` and `designcraft-cli`.
- [x] 5.3 Repeat task 3.3 for `app-office/designcraft` with package subdirectory `apps/designcraft`. Verify the new policy assertions pass.
- [x] 5.4 Repeat task 3.4 for `app-office/designcraft` and bare `designcraft`. Closed 2026-10-13 as deferred: `src_test` did not pass. The failure, the decision to leave the assertion unchanged, and the resume notes are in "Deferred upstream test failures" below.

## 6. app-office/deckcraft

- [x] 6.1 Repeat task 3.1 for `app-office/deckcraft` (`storytold/deckcraft`, `apps/deckcraft`). Under `gui?`, `DEPEND` and `RDEPEND` include `media-libs/alsa-lib`. Do not add `jack` or `pipewire`. The ebuild export of `CRAFT_FONTS_DIR`, when the font build script exists, is absolute so it wins over the unforced relative `.cargo/config.toml` entry. Verify the same artifacts as task 3.1 and that `alsa-lib` is conditional on `gui`.
- [x] 6.2 Repeat task 3.2 for `=app-office/deckcraft-<seedPV>` and binaries `deckcraft` and `deckcraft-cli`.
- [x] 6.3 Repeat task 3.3 for `app-office/deckcraft` with package subdirectory `apps/deckcraft`. Verify the new policy assertions pass.
- [x] 6.4 Repeat task 3.4 for `app-office/deckcraft` and bare `deckcraft`. `USE=test FEATURES=test` emerge of 0.6.1 completed on 2026-10-13. VDB `USE` and `FEATURES` include `test`, `RESTRICT` is empty, and `DEFINED_PHASES` includes `test`. `deckcraft 0.6.1` and `deckcraft-cli 0.6.1` each exited 0.

## 7. media-gfx/cadcraft

- [x] 7.1 Repeat task 3.1 for `media-gfx/cadcraft` (`storytold/cadcraft`, `apps/cadcraft`). Install the hicolor PNG sizes the tag ships. Do not require a scalable icon directory. Verify `src_install` succeeds its icon logic against the seed tree and that the ebuild does not call `doicon -s scalable` when `scalable/` is absent.
- [x] 7.2 Repeat task 3.2 for `=media-gfx/cadcraft-<seedPV>` and binaries `cadcraft` and `cadcraft-cli`.
- [x] 7.3 Repeat task 3.3 for `media-gfx/cadcraft` with package subdirectory `apps/cadcraft`. Verify the new policy assertions pass.
- [x] 7.4 Repeat task 3.4 for `media-gfx/cadcraft` and bare `cadcraft`. `USE=test FEATURES=test` emerge of 0.6.2 completed on 2026-10-13. VDB `USE` and `FEATURES` include `test`, `RESTRICT` is empty, and `DEFINED_PHASES` includes `test`. `cadcraft 0.6.2 (dev)` and `cadcraft-cli 0.6.2` each exited 0.

## 8. media-gfx/vectorcraft

- [x] 8.1 Repeat task 3.1 for `media-gfx/vectorcraft` (`storytold/vectorcraft`, `apps/vectorcraft`). Do not add `wgpu`, `accessibility`, or `windows7` USE flags. Verify the same artifacts as task 3.1 and that `IUSE` has none of those three names.
- [x] 8.2 Repeat task 3.2 for `=media-gfx/vectorcraft-<seedPV>` and binaries `vectorcraft` and `vectorcraft-cli`.
- [x] 8.3 Repeat task 3.3 for `media-gfx/vectorcraft` with package subdirectory `apps/vectorcraft`. Verify the new policy assertions pass.
- [x] 8.4 Repeat task 3.4 for `media-gfx/vectorcraft` and bare `vectorcraft`. Closed 2026-10-13 as deferred: `src_test` did not pass. The failure, the decision to leave the 10 ms budget unchanged, and the resume notes are in "Deferred upstream test failures" below.

## 9. media-gfx/lightcraft

- [x] 9.1 Repeat task 3.1 for `media-gfx/lightcraft` (`storytold/lightcraft`, `apps/lightcraft`). `IUSE` adds `+heif` and `rawnind-model`. The seed passes `--features heif` for both packages even when that tag's `package.sh` does not. `rawnind-model` passes `--features rawnind-model` only when enabled, and `LICENSE` does not include `GPL-3`. Do not add `avif`, `denoise`, or `dhat` USE flags. Build with `--release`; do not select `[profile.dist]`. Verify the ebuild contains `+heif`, `rawnind-model`, and the heif feature argument, and that `LICENSE` does not contain `GPL-3`.
- [x] 9.2 Repeat task 3.2 for `=media-gfx/lightcraft-<seedPV>` with default USE (heif on, rawnind-model off) and binaries `lightcraft` and `lightcraft-cli`.
- [x] 9.3 Repeat task 3.3 for `media-gfx/lightcraft` with package subdirectory `apps/lightcraft`. Verify the new policy assertions pass.
- [x] 9.4 Repeat task 3.4 for `media-gfx/lightcraft` and bare `lightcraft`. Verify the updated ebuild still contains `+heif` and `rawnind-model`. `USE=test FEATURES=test` emerge of 0.6.0 completed on 2026-10-13. VDB `USE` and `FEATURES` include `test`, `RESTRICT` is empty, and `DEFINED_PHASES` includes `test`. `lightcraft 0.6.0` and `lightcraft-cli 0.6.0` each exited 0. The 0.6.0 ebuild still has `IUSE` `+heif rawnind-model` and passes both as `--features` in `src_compile`.

## 10. media-sound/soundcraft

- [x] 10.1 Repeat task 3.1 for `media-sound/soundcraft` (`storytold/soundcraft`, `apps/soundcraft`). Under `gui?`, `DEPEND` and `RDEPEND` include `media-libs/alsa-lib`. Do not add `jack` or `pipewire`. Verify `alsa-lib` is conditional on `gui`.
- [x] 10.2 Repeat task 3.2 for `=media-sound/soundcraft-<seedPV>` and binaries `soundcraft` and `soundcraft-cli`.
- [x] 10.3 Repeat task 3.3 for `media-sound/soundcraft` with package subdirectory `apps/soundcraft`. Verify the new policy assertions pass.
- [x] 10.4 Repeat task 3.4 for `media-sound/soundcraft` and bare `soundcraft`. The first `USE=test` emerge failed because the VST3 probe opened ELF32 `/usr/lib/libz.so.1`. `src_prepare` now searches `/usr/lib64/libz.so.1` and `/lib64/libz.so.1` first. The re-emerge on 2026-10-13 completed. VDB `USE` and `FEATURES` include `test`, `RESTRICT` is empty, and `DEFINED_PHASES` includes `prepare` and `test`. `SoundCraft 0.6.1` and `SoundCraft CLI 0.6.1` each exited 0.

## 11. media-video/filmcraft

- [x] 11.1 Repeat task 3.1 for `media-video/filmcraft` (`storytold/filmcraft`, `apps/filmcraft`). `IUSE` adds default-off `whisper`, `neural-voices`, `vaapi`, and `nvenc`. `whisper` and `neural-voices` pass their features only when enabled, and only when the seed lock resolves that feature offline; otherwise omit the flag and record the missing crates. `vaapi` RDEPENDs `media-libs/libva`. `nvenc` RDEPENDs `x11-drivers/nvidia-drivers`. Neither adds a build dependency. `libglvnd` and `vulkan-loader` are unconditional. Under `gui?`, depend on `media-libs/alsa-lib`. Document `whisper`, `neural-voices`, and `nvenc` in `metadata.xml`. Verify those flags default off and that `DEPEND` does not include `libva` or `nvidia-drivers`.
- [x] 11.2 Repeat task 3.2 for `=media-video/filmcraft-<seedPV>` with default USE and binaries `filmcraft` and `filmcraft-cli`.
- [x] 11.3 Repeat task 3.3 for `media-video/filmcraft` with package subdirectory `apps/filmcraft`. Verify the new policy assertions pass.
- [x] 11.4 Repeat task 3.4 for `media-video/filmcraft` and bare `filmcraft`. Verify the updated ebuild still declares the flags kept in task 11.1. The 0.6.0 ebuild still declares `whisper`, `vaapi`, and `nvenc`. Closed 2026-10-13 as deferred: `src_test` did not pass. The failure, the decision to keep `filmcraft-golden` in `src_test`, and the resume notes are in "Deferred upstream test failures" below.

## 12. app-text/pdfcraft

- [x] 12.1 Repeat task 3.1 for `app-text/pdfcraft` (`storytold/pdfcraft`, `apps/pdfcraft`). Confirm the seed archive contains the `vendor/` path patches and that `pycargoebuild` runs against `apps/pdfcraft`. `BDEPEND` includes `dev-build/cmake` and `dev-lang/nasm`. `IUSE` adds default-off `cups`, which RDEPENDs `net-print/cups` when enabled. Do not add an `mcp` USE flag or a poppler or mupdf dependency. If the pack fails, record the error, leave tasks 12.2–12.4 unchecked, and continue at task 13. Verify `BDEPEND` names cmake and nasm and `IUSE` does not name `mcp`.
- [x] 12.2 Repeat task 3.2 for `=app-text/pdfcraft-<seedPV>` and binaries `pdfcraft` and `pdfcraft-cli`.
- [x] 12.3 Repeat task 3.3 for `app-text/pdfcraft` with package subdirectory `apps/pdfcraft`. Verify the new policy assertions pass.
- [x] 12.4 Repeat task 3.4 for `app-text/pdfcraft` and bare `pdfcraft`. Verify the updated ebuild still has default-off `cups` and the cmake and nasm `BDEPEND`. `USE=test FEATURES=test` emerge of 0.7.1 completed on 2026-10-13. VDB `USE` and `FEATURES` include `test`, `RESTRICT` is empty, and `DEFINED_PHASES` includes `test`. `pdfcraft 0.7.1` and `pdfcraft-cli 0.7.1` each exited 0. `IUSE` lists `cups` without a default-on prefix, and `BDEPEND` names `dev-build/cmake` and `dev-lang/nasm`.

## 13. media-video/effectcraft

- [x] 13.1 Repeat task 3.1 for `media-video/effectcraft` (`storytold/effectcraft`, `apps/effectcraft`). This is the `GIT_CRATES` spike: Linux `filmcraft-*` git crates stay, and windows-only and wasm-only git crates are omitted. Add `whisper`, `neural-voices`, `vaapi`, or `nvenc` only when the app crate exposes that feature and, for the two compile features, the seed lock resolves it offline. `libglvnd` and `vulkan-loader` are unconditional. Under `gui?`, depend on `media-libs/alsa-lib`. If the pack or the git-crate vendor step fails, record the error and leave tasks 13.2–13.4 unchecked. Verify, when the pack succeeds, that `GIT_CRATES` lists the Linux filmcraft pins and omits windows-only and wasm-only git crates.
- [x] 13.2 Repeat task 3.2 for `=media-video/effectcraft-<seedPV>` and binaries `effectcraft` and `effectcraft-cli`. Re-emerge on 2026-10-12 completed with default USE (`X cli gui portal wayland -debug -test`). `effectcraft 0.7.0` and `effectcraft-cli 0.7.0` each exited 0.
- [x] 13.3 Repeat task 3.3 for `media-video/effectcraft` with package subdirectory `apps/effectcraft`. Verify the new policy assertions pass.
- [x] 13.4 Repeat task 3.4 for `media-video/effectcraft` and bare `effectcraft`. The 0.9.2 ebuild is in the overlay and the test emerge reached `src_test`, so the Linux `filmcraft-*` git crates fetched. Closed 2026-10-13 as deferred: `src_test` did not pass. The failure, the decision to leave the assertion unchanged, and the resume notes are in "Deferred upstream test failures" below.

## 14. Integration gates

- [x] 14.1 Run `openspec validate add-storytold-craft-apps --type change --strict` and verify it exits 0. Re-run on 2026-10-14 after the git-crate fetch-line requirement exited 0.
- [x] 14.2 Run `just check` and verify the full `hk check` gate exits 0. Confirm README, CONTRIBUTING, and AGENTS are unchanged. Re-run on 2026-10-13 after `ensureGitCrateSrcUri` exited 0. ormolu, the release build, coverage, hlint, stan (79 modules, 0 observations), and weeder passed. README, CONTRIBUTING, and AGENTS are unchanged.

## Workflow follow-up

- Synced on 2026-10-14 into `openspec/specs/`, then archived. Modified requirements still contain their previous scenarios. `media-fonts-craft-fonts` and `storytold-craft-apps` keep their Purpose sections. Living specs contain no change-delta residue. The synced `cargo-crates-assets` spec includes "Git crate fetch line".
- `openspec validate --specs --strict` after the sync: 10 passed, 48 failed (58 items). Before the sync: 8 passed, 48 failed (56 items). The two new specs pass. The 48 failures are the same pre-existing requirement-length warnings, with cargo-crates-assets indexes shifted by the inserted requirements.

## Deferred upstream test failures

On 2026-10-13 the operator closed tasks 5.4, 8.4, 11.4, and 13.4 without a passing `src_test`. Each package stays installed with `test` off and `RESTRICT` containing `test`. The ebuilds still run the workspace tests when `USE=test` and `FEATURES=test` are set. This change does not patch the failing assertions. Resume from this section.

### app-office/designcraft 0.6.0 (task 5.4)

`USE=test FEATURES=test emerge =app-office/designcraft-0.6.0` failed in `src_test` on 2026-10-12. `designcraft-compose` ran 163 passed, 1 failed, 1 ignored. `tests::arabic_explicit_isolated_forms_disable_contextual_joining` panicked at `crates/compose/src/tests.rs:1735` (`left: 309`, `right: 596`). Installed binaries stayed `designcraft 0.6.0` with `test` off. The same assertion is unchanged at tag `v0.7.1`.

The font database loads the Japanese craft-fonts. The test sets glyph fallback, which scans system fonts. The first file with U+0628 by sorted path is `/usr/share/fonts/noto/NotoKufiArabic-Black.ttf`. Glyph 596 is `uni0628`. Glyph 309 is `dotbelowar`. Noto Sans Arabic under `/usr/share/craft-fonts` decomposes beh the same way.

Decision: leave the assertion unchanged. Log: `/var/tmp/portage/app-office/designcraft-0.6.0-2026-10-12T19:59:40-07:00/temp/build.log`.

### media-gfx/vectorcraft 0.10.0 (task 8.4)

`USE=test FEATURES=test emerge =media-gfx/vectorcraft-0.10.0` failed in `src_test` on 2026-10-13. `vectorcraft-text` ran 217 passed, 1 failed. `tests_typo::layout_10k_area_text_is_fast` panicked at `crates/text/src/tests_typo.rs:749`. JustifyLeft / EveryLine took 12.745 ms against the release budget of 10 ms. The debug budget is 400 ms. The test lays out 10,000 characters in a 400 by 20,000 frame, hyphenated, warms up once, then averages five `Instant` layouts. The other two cases did not run. Installed binaries stayed `vectorcraft 0.10.0` and `vectorcraft-cli 0.10.0` with `test` off. `v0.10.0` was still the newest tag.

The 12.745 ms sample shared the `vectorcraft-text` process with the other tests in that binary. `--test-threads=1` would keep those other tests off the CPU during the clock. Layout itself would stay as the crate wrote it. A quiet remeasure was not run. The portage tree for that emerge is gone.

Decision: option C, leave the 10 ms budget unchanged. Options not taken: A, measure that one test quietly and then either serialize `src_test` or raise the release budget from the quiet number; B, raise the release budget to 20 ms now; D, skip only this test. Log: `/var/tmp/portage/media-gfx/vectorcraft-0.10.0-2026-10-13T07:09:17-07:00/temp/build.log`.

### media-video/filmcraft 0.6.0 (task 11.4)

`USE=test FEATURES=test emerge =media-video/filmcraft-0.6.0` failed in `src_test` on 2026-10-13. `filmcraft-golden` ran 29 passed, 4 failed: `gpu_blend_modes_match_cpu_render`, `gpu_effect_chains_match_cpu_render`, `gpu_matches_cpu_on_golden_scenes`, and `gpu_transition_of_blended_clips_matches_cpu_render`. wgpu rejected render pipeline `fx-source` because `Rgba32Float` is not renderable on the TigerLake-LP GT2 Iris Xe (`8086:9a49`, i915, `/dev/dri/card0`). `crates/gpu/src/fx.rs` sets `FX_FORMAT` to `wgpu::TextureFormat::Rgba32Float`. The tests skip only when no adapter exists. The 0.6.0 ebuild still declares `whisper`, `vaapi`, and `nvenc`. Installed binaries stayed `filmcraft 0.6.0` with `test` off. Tag `v0.7.2` exists and its golden `device()` still skips only when no adapter exists.

Decision: keep `filmcraft-golden` in `src_test`. Do not add a format-capability skip. Log: `/var/tmp/portage/media-video/filmcraft-0.6.0-2026-10-13T12:06:52-07:00/temp/build.log`.

### media-video/effectcraft 0.9.2 (task 13.4)

`USE=test FEATURES=test emerge =media-video/effectcraft-0.9.2` failed in `src_test` on 2026-10-13. `effectcraft-ui-egui` ran 226 passed, 1 failed. `theme::tests::interface_symbols_have_a_glyph_in_every_family` panicked at `crates/ui-egui/src/theme.rs:667`: `•` has no glyph in `FontFamily::Name("medium")`. Proportional and monospace had accepted every symbol in `▸•›·▶◀●○⚠…×`, and medium had accepted `▸` before the bullet. The wasm32 `posterize-bands` error `can't find crate for std` is inside `example_wasm_plugin_loads_and_renders`, which passed.

`epaint` 0.36 `has_glyph` is false when the face chosen for a character is the family's replacement face: the first face whose cmap maps U+25FB `◻`, otherwise the first face whose cmap maps `?`. Medium and semibold are inserted without egui's Ubuntu Light, Noto Emoji, and emoji-icon font. Those builtin faces are the ones that contain U+25FB, so proportional's replacement face is Noto Emoji and monospace's is Hack. Inter Medium contains U+2022 `•` and `?`, and does not contain U+25B8 `▸` or U+25FB. JetBrains Mono contains `▸` and `•` and does not contain U+25FB. No English script fallback on this host contains U+25FB: KanjiStrokeOrders, then Noto Sans Arabic, Hebrew, Devanagari, Bengali, Gurmukhi, Gujarati, Tamil, Telugu, Kannada, Malayalam, and Thai. No Hangul face is installed. The replacement face is therefore Inter Medium via `?`. `▸` resolves to JetBrains Mono and passes. `•` resolves to Inter Medium and fails. Semibold was not reached and is built the same way. The script-fallback tests in the same file already avoid `has_glyph` and those tests passed.

The 0.9.2 ebuild is in the overlay (commits `4840f89` and prune `f35127d`). The `USE=test` emerge died before install. On 2026-10-13 a later default-USE emerge installed `media-video/effectcraft-0.9.2`. VDB `USE` is `X cli gui portal wayland`, `RESTRICT` is `test`, and `FEATURES` does not include `test`. `effectcraft 0.9.2` and `effectcraft-cli 0.9.2` each exited 0. `src_test` remains the deferred failure. `RESTRICT="!test? ( test )"` is why this emerge skipped `src_test`.

Decision: option A, leave the assertion unchanged. Options not taken: B, change this one test in `src_prepare` to the atlas-glyph check the script-fallback tests already use; C, put Noto Emoji on the medium and semibold families. Log: `/var/tmp/portage/media-video/effectcraft-0.9.2-2026-10-13T21:18:16-07:00/temp/build.log`.
