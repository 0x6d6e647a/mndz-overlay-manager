## Why

Full-path `update` of `dev-util/opencode` dies in the materialize container at `bun install`: `tree-sitter-powershell` `spawn('node-gyp', ['rebuild'])` is `ENOENT`. Bun’s hashed `node-gyp` stub is written under `--cache-dir` on the unit bind and advertised on overlay `$TMPDIR`, so `execve` misses. The image has Node 26.3 and headers under `/usr/include/node` but no `node-gyp` on `PATH`. We need a pinned overlay toolchain (qlot-shaped) so lifecycle scripts find a real binary and compile against the emerged Node, not `bun x` or nodejs.org header tarballs.

## What Changes

- Add overlay **`dev-build/node-gyp`** at npm **13.0.0** (openspec-shaped: registry `.tgz` + overlay-assets `{pn}-{pv}-deps.tar.xz`; `npm --offline --global --prefix` install). First deps tarball is packed **by hand in the current materialize image** (`npm` 11.16.0 is present). Not an opencode `BDEPEND`/`RDEPEND`.
- Wrapper `/usr/bin/node-gyp` plus materialize session env: `npm_config_nodedir=/usr`, `npm_config_python=/usr/bin/python3`, `PYTHON=/usr/bin/python3`. No session `npm_config_offline` (would break `bun install`).
- KEYWORDS: openspec-wide JS set, overlay tilde-only. Not bun-bin/`-*`, not copied from opencode.
- Manager policy: `Npm "node-gyp"` + `DepsAndAssets NpmEco`. `outdated`/`update` can bump it. Smoke: `update` 13.0.0 → **13.0.1**.
- **Extend `parseEnginesMinimum`** so `^X.Y.Z` and `A || B` are parseable (lowest lower-bound). node-gyp’s `engines.node` is `^22.22.2 || ^24.15.0 || >=26.0.0`; today’s parser would hard-fail plan.
- When the recipe has **bun or node**, also `emerge` overlay `dev-build/node-gyp::mndz` (scan overlay PV; overlay-bind `RUN` after `TkNode`). `nfNodeGyp` in image satisfies. Generator `mndz-overlay-manager-materialize-6`.
- File-gate: dirty preflight + rename/Manifest/egencache **before** `docker build` when this recipe emerges node-gyp. **No** overlay wait-edge (opencode/ralph still wait only on bun-bin). Signed commit is not required before docker.
- README: image node-gyp is overlay `::mndz`; nodedir/python; dirty/Manifest-before-docker names node-gyp when the recipe emerges it.

## Non-goals

- Overlay wait-edge from node-gyp (or qlot) to Bun/Sbcl consumers; bun-bin-style delayed GPG for node-gyp.
- `dev-build/gyp::gentoo` instead of node-gyp’s vendored **gyp-next**.
- Session `npm_config_offline`; TMPDIR-on-bind hide of Bun EXDEV; `--ignore-scripts` / dropping powershell from `trustedDependencies`.
- opencode ebuild `BDEPEND`/`RDEPEND` on node-gyp; re-running `bun install` under Portage.
- Waiting on oven-sh/bun #38079 / #38080.
- Host-path materialize; QEMU/foreign-arch.

## Capabilities

### New Capabilities

- `dev-build-node-gyp-seed`: Overlay `dev-build/node-gyp` (identity, distfiles, offline npm install, wrapper, KEYWORDS, isolation from opencode DEPEND, operator smoke).

### Modified Capabilities

- `npm-deps-assets`: `engines.node` parser accepts `^` and `||` (lowest lower-bound) so NpmEco planning of node-gyp does not hard-fail
- `ensure-materialize-image`: bun-or-node recipes emerge overlay node-gyp; `nfNodeGyp` in satisfies; Manifest-before-docker; generator `…-6`
- `hermetic-asset-materialize`: materialize session sets `npm_config_nodedir=/usr` and Python env so lifecycle `node-gyp rebuild` uses image headers
- `update-apply`: hardcoded policy `dev-build/node-gyp` is `Npm` + `DepsAndAssets NpmEco`; file work before a node-gyp-layer `docker build` when that recipe will emerge it
- `update-command`: dirty preflight includes overlay node-gyp when the recipe will emerge it
- `project-docs`: README materialize/update text matches overlay node-gyp and the dirty/Manifest gates
- `cli-activity`: node-gyp Manifest-before-docker is visible when that wait happens

## Impact

- **mndz-overlay**: new `dev-build/node-gyp/` (13.0.0 ebuild, wrapper, Manifest, `metadata.xml`, md5-cache).
- **mndz-overlay-assets**: `node-gyp-13.0.0-deps.tar.xz` (manual image pack); 13.0.1 via manager smoke.
- **mndz-overlay-manager**: `Update.Engines`; `Update.Hardcoded`; `Update.Materialize.{Recipe,Resolve,Floors,Ensure,Sidecar}`; `Update.Process.Docker` session env; dirty-preflight / overlay-atom-before-docker; tests; README.
- **Operator**: first full-path Bun or Npm `update` rebuilds `:local`. `update opencode` can pass `tree-sitter-powershell` install. `outdated`/`update` can list and bump `dev-build/node-gyp`.
