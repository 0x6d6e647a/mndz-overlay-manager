# Design

## Context

See `proposal.md` for why these packages are seeded at the previous comparable tag. PhotoCraft already plans this shape through `DepsAndAssets` Cargo: virtual workspace, lock at the clone root, `pycargoebuild` in `apps/<name>`, empty `CRATES`, donor phases preserved, and `policyArches` writing `KEYWORDS="-* ~arch"` for each allowlisted arch that has a lane target. `Update.Targets.resolveTargets` already accepts `category/package` and an unambiguous bare name. The image `mndz-overlay-manager/materialize:local` already exists. Do not rebuild it. Production assets live in `0x6d6e647a/mndz-overlay-assets`.

`storytold/craft-fonts` has no tags and no releases. `Cargo.toml` stays `0.1.0` while fonts are added. `parseNumeric` accepts only digits, dots, and an optional `-rN`, so a `_p` snapshot is `Raw` and `comparePV` will not order it against a later tag. `Unsupported` soft-skips `update` and does not live-fetch for `outdated`.

Tags move almost daily. Surveyed versions are not targets. Resolve the seed tag and the font commit on the day that artifact is packed.

## Goals / Non-Goals

**Goals:**

- Publish each app's predecessor crates release with the existing Cargo packer before that package's policy entry exists, then let `outdated` and `update` select the newest comparable numeric tag.
- Put the shared USE contract and every per-app flag into the seed ebuild so the Cargo rewrite keeps them.
- Install `craft-fonts` before any app seed whose tag has `crates/fonts/build.rs`, at numeric PV `0.0.0`, and register it as `Unsupported`.
- Keep a pack failure of EffectCraft or PdfCraft from blocking the other packages.

**Non-Goals:**

- A new planner, CLI flag, ecosystem, image recipe, or follow-main technique. Vocabulary stays `DepsAndAssets`, `GitMvAndManifest`, and `Unsupported`.
- Flipping `craft-fonts` to `GitMvAndManifest` before a comparable numeric tag exists.
- PhotoCraft body edits. Compile-time `X`, `wayland`, or `avif` switches. Keywords for `ppc` and `mips`.
- Packaging wasm, xtask, fuzz crates, or `docs/brand`. Emerging these packages inside the materialize image.

## Decisions

### Seed each predecessor outside `update`

`update` selects the newest comparable numeric tag. On pack day, list comparable tags for `storytold/<name>` (prefix `v`, numeric PVs only). The seed is the immediate previous tag. The newest tag is what the later `outdated` smoke must report. Pack that seed inside `mndz-overlay-manager/materialize:local` with the PhotoCraft `pycargoebuild` arguments: lock at the repository root, package directory `apps/<name>`, `--crate-tarball-prefix cargo_home/gentoo`, then the manager's hermetic tar/xz pack (`XZ_OPT=-T1 -9e`) and `b3`, `sha256`, and `sha512` sidecars. Publish assets release `<pn>-<seedPV>` with a GPG-signed assets commit before the policy entry. Work under `TMPDIR`, not `$HOME`. Leave an existing release tag untouched.

The ebuild inherits `cargo`, sets `CRATES=""`, and records the single harvested `RUST_MIN_VER` from the same floor walk the manager uses (workspace and registry crate `rust-version`; `eframe` is the practical floor). The primary `SRC_URI` is the tag archive. The crates `SRC_URI` uses `${PV}`.

Alternatives considered: calling `update` to create the seed (it skips the predecessor); `CargoCratesIo` (the product is the git workspace); pinning the destination PV on the CLI (package targets never select a version).

### One policy shape, two spikes

Add `policyArches` for each app: GitHub `storytold` / `<name>` / prefix `v`, technique `DepsAndAssets (Cargo Nothing (Just "apps/<name>") CargoGitTag)`, arches `amd64`, `x86`, `arm`, `arm64`, `ppc64`, `loong`, `riscv`, `sparc`, `s390`. The seed `KEYWORDS` string is `-* ~amd64 ~x86 ~arm ~arm64 ~ppc64 ~loong ~riscv ~sparc ~s390`. `ppc` and `mips` stay out because these trees use `AtomicU64` without a `target_has_atomic` gate. An empty allowlist would keyword those arches and make the first update revision-bump.

EffectCraft is the same Cargo entry. Its root manifest pins `filmcraft-*` crates with `git = https://github.com/storytold/filmcraft` at a raw revision. The existing rewrite drops only windows-only and wasm-only `GIT_CRATES`. Linux git crates stay. Pack this package on purpose and stop only this package if `pycargoebuild` or the emerge cannot vendor those crates offline. Do not invent a new ecosystem.

`cargo.eclass` fills `CARGO_CRATE_URIS` from `GIT_CRATES` and does not append it to `SRC_URI`. A Cargo rewrite of an ebuild with empty `CRATES` and a `GIT_CRATES` declaration writes `SRC_URI+=" ${CARGO_CRATE_URIS}"` after the assets crates tarball. An ebuild with empty `CRATES` and no `GIT_CRATES` declaration does not gain that line. A list-era ebuild, where `CRATES` is non-empty, keeps the existing rule that drops `${CARGO_CRATE_URIS}` as registry URIs.

PdfCraft is the same Cargo entry pointed at `apps/pdfcraft`. `[patch.crates-io]` path entries live in the tag archive under `vendor/` and are not git crates. The sign crate builds `aws-lc-sys`, so the ebuild `BDEPEND`s on `dev-build/cmake` and `dev-lang/nasm`. No poppler, mupdf, or `mcp` USE flag.

Alternatives considered: a pilot change for those two (rejected; they stay here and do not gate the others); clearing the allowlist.

### Classify the win7 vendor cfg

VectorCraft gates Windows dependencies with `cfg(all(windows, not(target_vendor = "win7")))` on the app and the CLI. `win7` is the vendor of Rust's windows7 target. That value holds for no modeled family, so the table is ignored and the tag stays complete. Any other `target_vendor` value stays unparsed, because `unknown` is the ordinary Linux vendor and must stay fail-closed.

Alternatives considered: treating every `target_vendor` value as holding for no family (would drop Linux crates gated on `target_vendor = "unknown"`); leaving `win7` unparsed (both the seed and `v0.9.0` stay incomplete, so `outdated` reports no lane).

### Copy the PhotoCraft body, then add the per-app lines

Shared donor, all eleven:

- `IUSE="+gui +cli +portal +X +wayland test"` and `REQUIRED_USE="|| ( gui cli ) gui? ( || ( X wayland ) )"`.
- `RESTRICT="!test? ( test )"`. `src_test` runs workspace tests excluding `<name>-web` and `xtask`.
- `src_compile` passes `-p <name>` and `-p <name>-cli` from the phase, never via `ECARGO_ARGS`. `src_install` uses `dobin` for the same flags.
- `portal`, `X`, and `wayland` are runtime dependencies. `eframe` hardcodes `wayland` and `x11`. `gui` RDEPENDs on dbus, `xdg-utils`, `libglvnd`, `vulkan-loader`, and `libxkbcommon`. `portal` selects `xdg-desktop-portal`; `!portal` selects zenity. No Vulkan ICD and no portal backend.
- Install the `packaging/linux` desktop id `ai.storyteller.<name>`, mime, the hicolor tree that exists, and metainfo with `@VERSION@` and `@DATE@` substituted. Do not install `docs/brand`. CADCraft has PNG sizes only; do not call `doicon -s scalable` when that directory is absent.
- App license `|| ( MIT Apache-2.0 )`. Crate licenses stay in the generated block. A second `LICENSE+=` after that block names only licenses of files the ebuild installs or embeds. Do not copy `SCOWL` onto packages that do not install it. Do not add `CC-BY-4.0` for LightCraft matrices that were fitted rather than copied.
- `metadata.xml` documents local flags and `maintainer-needed`. `cups` and `vaapi` are global. `cli`, `portal`, `heif`, `rawnind-model`, `whisper`, `neural-voices`, and `nvenc` are local.

Per-app lines, written into the seed so rewrite keeps them:

- LightCraft: `IUSE` adds `+heif` and `rawnind-model`. `heif` passes `--features heif` for both packages even when the seed tag's `package.sh` does not. `rawnind-model` passes `--features rawnind-model` and does not change `LICENSE`. The feature compiles a downloader. The GPL weights are not in the tag. `denoise` stays a default cargo feature with no USE flag.
- FilmCraft: `whisper` and `neural-voices` pass their features when enabled. `vaapi` RDEPENDs `media-libs/libva`. `nvenc` RDEPENDs `x11-drivers/nvidia-drivers`. Neither flag adds a build dependency. All four default off.
- EffectCraft: same four flags only when the app crate exposes the feature and a locked resolve can build it offline. Otherwise omit that flag and record the gap. `libglvnd` and `vulkan-loader` are unconditional on EffectCraft and FilmCraft because the CLI links the GPU stack.
- DeckCraft, SoundCraft, EffectCraft, and FilmCraft: `media-libs/alsa-lib` in `DEPEND` and `RDEPEND` under `gui?`. No `jack` or `pipewire` flag.
- PdfCraft: `cups` defaults off and RDEPENDs `net-print/cups` when on.
- Any tag with `crates/fonts/build.rs`: `BDEPEND="media-fonts/craft-fonts:="` and `export CRAFT_FONTS_DIR=/usr/share/craft-fonts` plus `CRAFT_FONTS_REQUIRED=1`. The path is absolute. DeckCraft's `.cargo/config.toml` sets a relative path and does not force it, so the export wins.

`whisper` and `neural-voices` download models at runtime. That matches the `rawnind-model` downloader. Do not vendor those models.

Alternatives considered: unconditional font export on every app (an app without the build script warns or errors under `CRAFT_FONTS_REQUIRED`); a `GPL-3` `LICENSE` line for a flag that does not ship the weights.

### Register craft-fonts as a data package

Install the commit of `main` resolved on pack day. `SRC_URI` is `https://github.com/storytold/craft-fonts/archive/<full-sha>.tar.gz`. Install `fonts/manifest.txt` and the family directories so `/usr/share/craft-fonts/fonts/manifest.txt` exists. `LICENSE="OFL-1.1"`. `SLOT="0/${PV}"`. Do not build the repo's Rust crate and do not install fontconfig config. Keywords match the apps. The operator emerges this package before any app seed.

Policy is `Unsupported` with reason text that `storytold/craft-fonts` publishes no comparable numeric tag. `update` soft-skips. The PV `0.0.0` is what makes a later `v0.1.0` compare greater once a follow-up switches the technique to `GitMvAndManifest`. This change does not perform that switch.

Alternatives considered: PV `0.1.0_p<date>` (Raw, so `outdated` would not see a later numeric tag); waiting for upstream to tag (the seed bodies would omit the export, and adding it after `update` is a `-r1` on every consumer); following `main` (every font commit would rebuild every consumer).

### Test the policy once, then smoke per package

Extend `test/Test/Policy.hs` for each new key: `lookupPolicy`, `resolveSource`, `lookupLaneArches`, and qualified plus bare target resolution with no version pin. One donor-preservation fixture rewrites a donor that carries `+heif`, `rawnind-model`, `cups`, `whisper`, the workspace `src_test` excludes, and a `CRAFT_FONTS_DIR` export. Assert those survive and that `CRATES`, the generated license block, `RUST_MIN_VER`, `KEYWORDS`, and the assets URL may change.

Operator acceptance is separate. Emerging needs the operator's sudo password. The agent hands the command and does not run `sudo`. One LTO emerge at a time. After each seed install, `<name> --version` and `<name>-cli --version` must print a version and exit 0. Then `outdated` must report the newest comparable tag and `update` must apply it without overwriting the seed assets release. The operator builds that newer ebuild with `USE=test` and `FEATURES=test`.

On 2026-10-13 the operator closed the four `src_test` failures as deferred work. Designcraft 0.6.0, vectorcraft 0.10.0, filmcraft 0.6.0, and effectcraft 0.9.2 keep the upstream tests in `src_test`. This change does not patch those assertions. The resume log is the "Deferred upstream test failures" section of `tasks.md`. The other seven apps passed `USE=test`.

Overlay commits stay one-line subjects of the form `category/pn: <PV>`, GPG-signed. Assets commits are GPG-signed and land before the matching policy entry. Manager commits stay Conventional Commits and GPG-signed. A manager commit may include only packages whose assets release already exists.

## Risks / Trade-offs

- [Risk] A newer tag appears between the survey and pack day. → Resolve the previous comparable tag that day. `update` still selects whatever is newest at smoke time. The seed release stays published.
- [Risk] The seed `KEYWORDS` string differs from the allowlist output. → Copy the allowlist string into every seed before the first `update`.
- [Risk] The extra `LICENSE+=` sits inside the generated block. → Place it after the marked block and assert a donor term outside the block survives the fixture.
- [Risk] EffectCraft's git crates are not in the registry tarball. → Spike that pack first among the risky packages. On failure, leave EffectCraft's later tasks open and continue.
- [Risk] PdfCraft's `aws-lc-sys` build needs cmake and nasm, or the missing `designcraft` testkit path breaks metadata. → Record the failure against that package and continue with the others. A missing testkit directory did not fail `cargo metadata --no-deps` on the surveyed tag; a locked fetch still might.
- [Risk] `whisper` or `neural-voices` is absent from the lock when the feature is off. → Omit the flag. Do not add a network fetch during `src_compile`.
- [Risk] LightCraft's seed `package.sh` does not pass `heif`, so a body copied from upstream scripts would drop `+heif`. → Write the flag into the seed ebuild anyway.
- [Risk] LightCraft `[profile.dist]` is not `[profile.release]`. Portage builds `--release` and will not use the dist profile. → Accept the release profile. Do not add a custom cargo profile.
- [Risk] `USE=portal` with no portal backend leaves file dialogs dependent on zenity's fallback. → Same contract as PhotoCraft. Do not add a backend dependency.
- [Risk] Eleven seed tarballs plus eleven update tarballs. → About a gigabyte of assets, one pack at a time under `TMPDIR`. `/var/tmp` holds one emerge at a time.
- [Risk] A font bump does not rebuild consumers without a subslot operator. → `SLOT="0/${PV}"` and `BDEPEND="media-fonts/craft-fonts:="`. Confirm the operator during the first app emerge.

## Migration Plan

1. Add `media-fonts/craft-fonts-0.0.0`, Manifest, and md5-cache. The operator emerges it. Add the `Unsupported` policy entry.
2. For each app, in an order that leaves PdfCraft and EffectCraft last: resolve the seed tag, pack and publish assets, write the donor, operator-emerge the seed, add the policy entry, run `outdated` and `update`, operator-emerge the update with tests.
3. A failed spike stops that package only.
4. Run `openspec validate add-storytold-craft-apps --type change --strict` and `just check`. README, CONTRIBUTING, and AGENTS stay unchanged.
5. After those gates pass, sync the delta specs into `openspec/specs/` and archive the change.

Rollback is the policy commits in this repository. Each overlay package reverts with its own commit. A published assets tag stays for any ebuild that names it. The `craft-fonts` snapshot stays installed until its overlay commit is reverted; app binaries that already embedded the fonts do not need it at runtime.

## Open Questions

None. Apply-time checks (which tags contain `crates/fonts/build.rs`, which EffectCraft features exist, whether an optional feature resolves offline) are decided above.
