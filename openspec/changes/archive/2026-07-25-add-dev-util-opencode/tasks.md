## 1. Overlay bootstrap (mndz-overlay + assets)

- [x] 1.1 Delete untracked `dev-util/opencode-bin/` from mndz-overlay (ebuild, Manifest, metadata.xml)
- [x] 1.2 Author `dev-util/opencode-1.18.4.ebuild` + `metadata.xml` per design contract (`~amd64`, `IUSE="bash-completion +webui zsh-completion"`, BDEPEND bun-bin, RDEPEND ripgrep, SRC_URI github + deps + models, monorepo compile, completions via `SHELL=… opencode completion`)
- [x] 1.3 Materialize `opencode-1.18.4-deps.tar.xz` (bun-cache from tag `v1.18.4`) and `opencode-1.18.4-models.json` (from models.dev)
- [x] 1.4 Publish both assets under GitHub release tag `opencode-1.18.4` on mndz-overlay-assets; write sidecars under `dev-util/opencode/`; signed commit/push
- [x] 1.5 Generate Manifest and package md5-cache; commit overlay package

## 2. Policy and Bun probe (manager)

- [x] 2.1 Remove `dev-util/opencode-bin` from `Update.Hardcoded`; add `dev-util/opencode` as GitHub `anomalyco/opencode` `v` + `DepsAndAssets Bun`
- [x] 2.2 Implement `packageManager` `bun@X.Y.Z` fallback in Bun engines parsing (engines.bun wins when parseable)
- [x] 2.3 Wire probe into planning, host gate, and BDEPEND alignment; confirm RDEPEND is not forced to bun-bin
- [x] 2.4 Unit tests for engines vs packageManager precedence and missing-both hard-fail

## 3. Multi-asset publish and reuse

- [x] 3.1 Extend assets layout helpers for models basename `{pn}-{pv}-models.json` and multi-sidecar staging
- [x] 3.2 Generalize release create/upload to N assets; delete release on any upload failure after create
- [x] 3.3 Multi-asset reuse: success only when all required basenames exist and download
- [x] 3.4 Keep single-asset packages (Go/npm/ralph/cargo) working as list-of-one
- [x] 3.5 Tests for multi-asset publish, partial-release non-reuse, and single-asset regression

## 4. Opencode materialize path

- [x] 4.1 On full materialize for opencode: build deps tarball and fetch models.dev → models JSON
- [x] 4.2 Publish both assets under one release; overlay rewrite includes both SRC_URI asset lines when parameterized
- [x] 4.3 Content-fix / Manifest incompleteness treats missing models DIST like missing deps where applicable
- [x] 4.4 Integration-style tests for opencode materialize (fakes for HTTP/process) covering full and reuse paths

## 5. Spec scrub and test retargeting

- [x] 5.1 Replace all remaining `opencode-bin` references in manager tests (`Policy`, `CheckPlan`, `Apply`, `Targets`, `Md5Cache`, etc.) with `opencode` (Bun) or other GitMv packages (`deno-bin`/`grok-build-bin`)
- [x] 5.2 Add/adjust policy and outdated scenarios for `dev-util/opencode` Bun enablement
- [x] 5.3 Ensure living delta specs stay consistent with implementation; run `openspec validate` for the change

## 6. Quality gates and first automated bump

- [x] 6.1 Run full project gate (`hk check` / CONTRIBUTING pipeline) and fix failures
- [ ] 6.2 With manager built and overlay at 1.18.4, run `update dev-util/opencode` (or equivalent) to produce **1.18.5** (new deps+models assets, ebuild bump, Manifest, md5-cache, signed commits)
- [ ] 6.3 Smoke: emerge or binary `--version` / `completion` generation as practical on the operator host
