## Context

See `proposal.md` for motivation. Full-path Bun `bun install` in the materialize container dies with `spawn node-gyp ENOENT` (`tree-sitter-powershell`). Host bun 1.4.0 still has oven-sh/bun #38079 (hashed stub on `$TMPDIR` after EXDEV). Manager `--cache-dir` is on the unit bind; container `$TMPDIR` is overlay `/tmp`. Image Node is 26.3.0; `process.config.variables.use_prefix_to_find_headers` is false; `node.h` and `common.gypi` live under `/usr/include/node`; `npm` is `/usr/sbin/npm` 11.16.0. Generator is `mndz-overlay-manager-materialize-5`. Overlay has no `dev-build/node-gyp`. `parseEnginesMinimum` rejects `^` and `||`. Forced session env is `HOME` / `XDG_*` / `PATH` / `SBCL_*` only.

## Goals / Non-Goals

**Goals:**

- Overlay `dev-build/node-gyp` 13.0.0 (openspec-shaped) with a docker-packed deps tarball; wrapper defaults `nodedir=/usr` and python3.
- Manager `NpmEco` for `node-gyp`; engines parser accepts caret and `||`; recipe/floors/file-gate like qlot; session env matches the wrapper; smoke `update` 13.0.0 → 13.0.1.
- Image `node-gyp` on `PATH` so opencode `bun install` can spawn it.

**Non-Goals:**

- Overlay wait-edge; TMPDIR-on-bind; `npm_config_offline`; `dev-build/gyp::gentoo`; opencode `BDEPEND`; Bun upstream fix.

## Decisions

### 1. Seed 13.0.0 in the current materialize image, then NpmEco

- Operator `docker run` of `mndz-overlay-manager/materialize:local`: `npm pack node-gyp@13.0.0`, `npm --userconfig <empty> --cache npm-cache install` the tarball, hermetic `tar` of `npm-cache/` (omit `_logs` / `_update-notifier*`). Publish `node-gyp-13.0.0-deps.tar.xz`. Write `node-gyp-13.0.0.ebuild` like openspec (`SRC_URI` registry `.tgz` + assets deps; `npm --offline --global --prefix "${ED}/usr"`).
- Policy: `Npm "node-gyp"` + `DepsAndAssets NpmEco`. First `update` after seed can plan 13.0.1 (engines parser A). `npm pack` of node-gyp does not need `node-gyp` on `PATH`.
- **Alternative — GitHub tag + homemade `node_modules/` tarball:** extra layout, not what `Update.Npm.Cache` produces. Rejected.
- **Alternative — GitMv-only / pin forever:** rejected (full support).

### 2. Wrapper plus session env; `nodedir=/usr`

- Ebuild installs a `/usr/bin/node-gyp` wrapper that `export`s `npm_config_nodedir=/usr`, `npm_config_python=/usr/bin/python3`, `PYTHON=/usr/bin/python3` when unset, then `exec`s the npm-global bin. Host emerge is hermetic too.
- `materializeCreateArgs` sets the same three on the session (forced keys; exec cannot drop them). Do **not** set `npm_config_offline`.
- Live image: prefix layout, not Gentoo’s old `/usr/include/node` fake source tree (`src/` symlink gone). node-gyp 13 looks up `nodeDir/include/node/common.gypi` first → `/usr` hits; `/usr/include/node` would miss `node.h` under `include/node/`.
- **Alternative — session only:** host `emerge node-gyp` would still download headers. Rejected.
- **Alternative — `nodedir=/usr/include/node`:** stale elog; confirmed miss on this image. Rejected.

### 3. Engines parser: caret and `||`

- `^X.Y.Z` → minimum `X.Y.Z` (no Portage encoding of the caret cap).
- `A || B || …` of those clauses → **lowest** lower-bound.
- Still fail `*`, `<`, hyphen ranges.
- node-gyp 13.0.1 `^22.22.2 || ^24.15.0 || >=26.0.0` → BDEPEND `>=net-libs/nodejs-22.22.2[npm]`. Seed ebuild may hardcode that atom before the parser ships.
- **Alternative — skip engines for this package:** special-case. Rejected.

### 4. Recipe: `TkNodeGyp` after Node, when bun or node

- New `ToolchainKind` like `TkQlot`. Overlay-bind `RUN` after `TkNode`, before Go/Bun (`kindRank`).
- Floor `nfNodeGyp` when `nfBun` or `nfNode` is set; scan newest non-live overlay PV. JSON key `"nodeGyp"` / `.:?` so old sidecars decode `Nothing`. Missing recorded node-gyp while needed is a miss.
- Generator → `mndz-overlay-manager-materialize-6`. Do not bump `imageSidecarSchemaVersion`.
- **Alternative — extra on `TkNode` only:** bun-only recipes that already install Node would still need an explicit overlay-bind RUN; a kind keeps bind vs gentoo emerge obvious. Chosen: own kind, trigger bun∨node.

### 5. File-gate, not wait-edge

- Dirty preflight + Manifest/egencache before docker when this recipe emerges node-gyp (generalize the qlot atom list).
- Commit-on-unit-success immediately after overlay apply (not bun-bin delay). `overlayCeilingProvider` stays Bun-only.
- **Alternative — withhold opencode on node-gyp GPG:** empty hypo (node-gyp PV does not change opencode tags). Rejected.

### 6. Tests and docs

- `Test.Ensure`: bun/node recipe emerges overlay node-gyp after node; Go-only omits it; accept_keywords `::mndz`; overlay bind; newer node-gyp rebuilds.
- `Test.Policy` / outdated: NpmEco `node-gyp`.
- `Test.Engines` / properties: caret, `||`, star still fails.
- `Test.Ecosystems`: docker create argv includes nodedir/python; no `npm_config_offline`.
- README: overlay node-gyp; dirty/Manifest gates.

## Risks / Trade-offs

- **[Risk]** `node-gyp rebuild` of unused powershell `.node` fails after ENOENT is gone → **Mitigation:** image already has Node 26 headers, Python 3.14, gcc; treat a gyp error as a new bug. Verify with `update opencode`.
- **[Risk]** Seed deps tarball omits `_logs` / xz and 13.0.0 emerge fights Portage → **Mitigation:** copy `Update.Npm.Cache` + hermetic tar flags in the manual docker recipe; 13.0.1 is the manager-faithful artifact.
- **[Risk]** Sidecar without `nodeGyp` while bun/node needed → **Mitigation:** `Nothing` vs `Just pv` fails satisfy; generator-6 rebuilds.
- **[Risk]** Wrapper path vs npm `--prefix /usr` bin location → **Mitigation:** wrapper `exec`s the installed global bin after locating it under `${ED}/usr`.

## Migration Plan

1. Manual docker pack + overlay 13.0.0 + Manifest + smoke emerge / `node-gyp --version`.
2. Manager: engines, policy, floors, recipe, session env, dirty/file-gate, tests, README. `hk check`.
3. `update node-gyp` → 13.0.1. First bun/node full-path `update` rebuilds `:local`. `update opencode` is the consumer proof.

## Open Questions

- (none)
