## 1. Overlay seed 13.0.0

- [x] 1.1 In `mndz-overlay-manager/materialize:local`, `npm pack node-gyp@13.0.0` then `npm --userconfig <empty> --cache npm-cache install` the tarball; drop `npm-cache/_logs` and `_update-notifier*`; hermetic `tar` (`XZ_OPT=-T1 -9e`, owner 0) of top-level `npm-cache/` to `node-gyp-13.0.0-deps.tar.xz`; verify the file is xz and lists `npm-cache/`
- [x] 1.2 Publish that deps tarball to mndz-overlay-assets as release `node-gyp-13.0.0` and verify the download URL used in `SRC_URI` fetches
- [x] 1.3 Add `dev-build/node-gyp/metadata.xml` with GitHub remote-id `nodejs/node-gyp` and verify it validates as pkgmetadata
- [x] 1.4 Write `node-gyp-13.0.0.ebuild`: openspec-shaped `SRC_URI` (registry `.tgz` + assets deps); `KEYWORDS` tilde JS set (not `-*`); `RDEPEND`/`BDEPEND` `>=net-libs/nodejs-22.22.2[npm]` and python; `IUSE=test`; wrapper `/usr/bin/node-gyp` defaulting `npm_config_nodedir=/usr` and python3 without `npm_config_offline`; `npm --offline --global --prefix`; no `dev-build/gyp`; no opencode DEPEND; verify `ebuild … manifest` and package `egencache` succeed
- [x] 1.5 Confirm `dev-util/opencode` ebuilds do not list `dev-build/node-gyp` as a dependency
- [x] 1.6 Emerge `=dev-build/node-gyp-13.0.0` and run `node-gyp --version` from `PATH`; verify the output contains `13.0.0`

## 2. Engines parser and policy

- [x] 2.1 Extend `parseEnginesMinimum` for `^X.Y.Z` and `||` (lowest lower-bound); keep `*`, `<`, hyphen ranges unparseable; verify unit/property tests: caret, node-gyp disjunction → `22.22.2`, star still `Nothing`
- [x] 2.2 Add `dev-build/node-gyp` to `hardcodedPolicies` as `Npm "node-gyp"` + `DepsAndAssets NpmEco`; verify policy lookup and that planning `node-gyp@13.0.1` does not hard-fail engines

## 3. Image floors and recipe

- [x] 3.1 Add optional `nfNodeGyp` to `NeededFloors` (JSON key that old sidecars decode as missing); set it when this prepare has bun or node; union/satisfy; missing recorded node-gyp while needed is a miss; verify newer overlay node-gyp rebuilds
- [x] 3.2 Add `TkNodeGyp`; resolve overlay metas; emerge spec `>=dev-build/node-gyp-<pv>::mndz` and `~arch` accept_keywords; overlay-bind `RUN` after Node and before bun; Go-only omits node-gyp; verify `Test.Ensure` recipe assertions
- [x] 3.3 Bump `materializeGeneratorId` to `mndz-overlay-manager-materialize-6` and verify skip requires matching generator

## 4. Session env and overlay gates

- [x] 4.1 Forced session env includes `npm_config_nodedir=/usr`, `npm_config_python=/usr/bin/python3`, `PYTHON=/usr/bin/python3` and does not set `npm_config_offline`; verify docker create argv tests
- [x] 4.2 Dirty-preflight overlay node-gyp when this recipe will emerge it; overlay file work (Manifest, egencache) before that `docker build`; node-gyp commit not delayed for ensure; opencode not withheld on node-gyp; verify dirty node-gyp fails before docker
- [x] 4.3 Progress: node-gyp Manifest wait visible when it happens; opencode not shown as waiting on `dev-build/node-gyp`

## 5. Docs, smoke, gates

- [x] 5.1 Update `README.md` runtime/materialize/`update` text (overlay node-gyp, nodedir/python, dirty/Manifest gates, not a wait-edge)
- [x] 5.2 `update dev-build/node-gyp` produces 13.0.1 deps + ebuild; verify `outdated`/`update` see npm latest and apply succeeds
- [x] 5.3 After ensure rebuilds `:local` with overlay node-gyp, `update opencode` gets past `tree-sitter-powershell` `spawn node-gyp` (no `ENOENT`)
- [x] 5.4 `openspec validate add-dev-build-node-gyp --strict --type change`
- [x] 5.5 `hk check`
