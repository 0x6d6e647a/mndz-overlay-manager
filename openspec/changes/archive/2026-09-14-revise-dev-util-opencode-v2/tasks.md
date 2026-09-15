## 1. Manager: drop models companion

- [x] 1.1 Remove `dev-util/opencode` extras from Adequacy `requiredAssetBasenames` / companion materialize fetch so opencode’s required set is deps-only; verify unit tests that previously required `opencode-${PV}-models.json` now succeed with deps alone and treat an extra models.json on the tag as unused
- [x] 1.2 Stop `materializeCompanionAssets` models.dev fetch for opencode; verify a full-path materialize test does not call the models fetcher and does not fail when models.json is absent

## 2. Manager: bun-exact ebuild body rewrite

- [x] 2.1 Add compile-pin ebuild rewrite that replaces versioned `bun-<X.Y.Z>` command tokens in `src_compile` / `src_test` with `bun-<exact>` while leaving comments alone; verify `Test.EbuildEdit` (or equivalent) that a donor with `bun-1.3.14` and pin `1.4.2` yields `bun-1.4.2` in compile and test and still writes `BDEPEND="~dev-lang/bun-bin-1.4.2"`
- [x] 2.2 Wire the rewrite into overlay apply next to `ensureBunBdependFor`; verify an apply/overlay-write test shows both BDEPEND and the bun invocation tracking the probed pin

## 3. Manager: clone-time cwd and build.ts guard

- [x] 3.1 After opencode GitHub clone on the full path, parse `src_compile` `cd` and hard-fail if that directory or `script/build.ts` under it is missing, naming the path and PV; verify tests for missing `packages/opencode`, missing `build.ts`, and success when `packages/cli/script/build.ts` exists
- [x] 3.2 Confirm the guard does not rewrite the `cd` target; verify a test that a donor `cd packages/opencode` on a v2 tree hard-fails rather than becoming `packages/cli`

## 4. Manager: fixtures and tests for v2 layout

- [x] 4.1 Update tests/fixtures that assume opencode compile cwd `packages/opencode` or `--skip-embed-web-ui` as product contract (keep generic InstallTree `node_modules` collection tests if they are not opencode-specific); verify `hk check` test step covers the new rewrite/guard/models-drop cases

## 5. Overlay: bun-bin-1.4.2-r1

- [x] 5.1 Publish `dev-lang/bun-bin-1.4.2-r1.ebuild` with the current SLOT=0 `newbin bun-${PV}` + symlink template; regenerate Manifest and md5-cache; verify `qlist` after emerge lists `/usr/bin/bun-1.4.2` and `/usr/bin/bun` → `bun-1.4.2`

## 6. Overlay: opencode-2.0.3-r1

- [x] 6.1 Write `dev-util/opencode-2.0.3-r1.ebuild`: `cd packages/cli`; `bun-1.4.2 --bun ./script/build.ts --single --skip-install` (`--skip-web-ui` when `-webui`); `NODE_OPTIONS=--max-old-space-size=4096`; `OPENCODE_VERSION`/`OPENCODE_CHANNEL=prod`; no models `SRC_URI` or `MODELS_DEV_API_JSON`; `OPENCODE_DISABLE_MODELS_FETCH=1` in Portage phases only; install ELF under libexec and `/usr/bin/opencode` wrapper with `OPENCODE_DISABLE_AUTOUPDATE=1`; dist glob `packages/cli/dist/cli-*/bin/opencode`; `--completions bash|zsh|fish` + `fish-completion` IUSE; ftrace `addwrite`; `src_test` from `packages/cli` with `bun-1.4.2 test --timeout 30000 --only-failures` and no skip of failing files; `RESTRICT="strip !test? ( test )"`; comment that Gentoo updates are emerge not `opencode upgrade --method curl`. Verify ebuild text.
- [x] 6.2 Regenerate opencode Manifest (deps + GitHub source; no models DIST) and md5-cache; verify Manifest has no `opencode-2.0.3-models.json`
- [x] 6.3 `emerge =dev-util/opencode-2.0.3-r1` under FEATURES including `network-sandbox`; verify `opencode --version` contains `2.0.3`, wrapper exports `OPENCODE_DISABLE_AUTOUPDATE`, and `bun-1.4.2` was used at compile

## 7. Specs merge and gates

- [x] 7.1 Merge this change’s spec deltas into `openspec/specs/` (`bun-deps-assets`, `assets-publish`, `overlay-test-use`); scrub delta residue; verify `openspec validate --strict`
- [x] 7.2 `hk check` green over the manager change
