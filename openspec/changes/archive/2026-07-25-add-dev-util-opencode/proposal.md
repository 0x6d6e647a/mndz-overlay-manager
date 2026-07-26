## Why

OpenCode is a first-class coding agent we want in the mndz Gentoo overlay as a **from-source** package (`dev-util/opencode`), not a prebuilt redistributor. Upstream builds with Bun (`packages/opencode/script/build.ts --single`), embeds the web UI by default (same as GitHub release / former local `opencode-bin` experiments), and pins tooling via `packageManager: "bun@…"`. The overlay-manager already automates Bun packages (`ralph-tui`) but cannot plan packages that lack `engines.bun`, publishes only a single release asset, and still hardcodes an unpublished `dev-util/opencode-bin` GitMv policy used widely in tests and living specs. We need an official overlay package at v1.18.4, manager support for automated bumps (including models.dev snapshot + bun-cache assets), and complete removal of `opencode-bin`.

## What Changes

- **Overlay (sibling repo work, sequenced with manager):** add `dev-util/opencode` ebuild (bootstrap **1.18.4** with deps + models assets, Manifest, md5-cache); delete untracked local `dev-util/opencode-bin/`; later bump to **1.18.5** via manager `update`.
- **Policy:** remove `dev-util/opencode-bin` (`GitHub` + `GitMvAndManifest`); add `dev-util/opencode` as `GitHub anomalyco/opencode` tag prefix `v` + `DepsAndAssets Bun`.
- **Bun requirement probe:** general fallback when `engines.bun` is missing — parse `packageManager` form `bun@X.Y.Z` as the minimum Bun version for lanes, host gate, and `>=dev-lang/bun-bin-…` BDEPEND alignment (`engines.bun` still wins when present).
- **Assets:** generalize publish/reuse to **multiple assets per release tag** `{pn}-{pv}`; for opencode publish and require both `{pn}-{pv}-deps.tar.xz` (bun-cache) and `{pn}-{pv}-models.json` (models.dev API snapshot fetched at materialize).
- **Ebuild contract (authored in overlay; manager rewrites PV/KEYWORDS/BDEPEND/SRC_URI patterns):** `KEYWORDS="~amd64"`; `IUSE="bash-completion +webui zsh-completion"`; `BDEPEND` bun-bin only; `RDEPEND=sys-apps/ripgrep` (no runtime bun); compile with `build.ts --single --skip-install` and optional `--skip-embed-web-ui` when `-webui`; models via `MODELS_DEV_API_JSON`; bash/zsh completions via `SHELL=… opencode completion` (no fish — yargs does not emit fish).
- **Tests & living specs:** retarget all `opencode-bin` GitMv exemplars to another GitMv package; add opencode Bun enablement coverage.
- **Non-goals:** npm `opencode-ai` packaging; keeping or publishing `opencode-bin`; fish completion; multiarch KEYWORDS beyond `~amd64`; building desktop/Electron; runtime models.dev fetch as a substitute for the compile-time snapshot; inventing CLI PV pins.

## Capabilities

### New Capabilities

- *(none)* — behavior extends existing assets, Bun deps, and update-apply policy surfaces.

### Modified Capabilities

- `bun-deps-assets`: Bun version probe accepts `packageManager bun@X.Y.Z` fallback; opencode end-to-end enablement under `DepsAndAssets Bun`; models companion distfile on full materialize; build-time-only bun-bin (BDEPEND) semantics for compiled packages.
- `assets-publish`: multi-asset GitHub release create/upload; multi-asset reuse (all named assets required); models distfile basename and sidecars; checksum commit may cover multiple distfiles for one PV.
- `update-apply`: hardcoded policy map drops `opencode-bin`, includes `dev-util/opencode` as Bun DepsAndAssets; scenarios that used `opencode-bin` as GitMv exemplar retargeted.
- `outdated-command`: scenarios/examples using `opencode-bin` retargeted.
- `update-command`: scenarios/examples using `opencode-bin` retargeted.

## Impact

- **Code:** `Update.Hardcoded`, `Update.Bun.Cache` / engines parsing, `Update.Deps.Plan` Bun probe, `Update.Assets.Layout` / `Release` multi-asset publish+reuse, `Update.Apply.Materialize` (opencode models fetch + multi-asset), overlay rewrite paths for Bun BDEPEND; extensive tests (`Policy`, `CheckPlan`, `Apply`, `Targets`, `Md5Cache`, assets).
- **Sibling systems:** mndz-overlay (`dev-util/opencode` ebuild); mndz-overlay-assets (release `opencode-${PV}` with deps + models assets and sidecars under `dev-util/opencode/`).
- **Runtime tools:** host `bun` ≥ packageManager floor; existing `dev-lang/bun-bin` ceilings (e.g. 1.3.14); network only on full materialize (registry + models.dev), not under Portage sandbox emerge.
- **Operators:** `update dev-util/opencode` (or bare `opencode` once unambiguous) drives bumps; first automated target after bootstrap is 1.18.5.
