## Why

`dev-util/opencode` fails under Portage `network-sandbox` during `src_compile`: the ebuild runs `bun install --frozen-lockfile --cache-dir …` against a published **bun-cache** deps tarball, but Bun still performs registry and `github:` fetches (e.g. `ghostty-web@github:…`) and dies with `ConnectionRefused`. Offline emerge is a hard product requirement; weakening the sandbox is not an acceptable long-term fix. We need the deps asset to carry a **pre-linked install tree** so compile can skip `bun install` entirely.

## What Changes

- **Bun materialize for opencode:** after clone + `bun install` on the full materialize path, package the **install tree** (workspace `node_modules` layout under the repo root) into `{pn}-{pv}-deps.tar.xz` instead of only a bare `bun-cache/` directory.
- **Overlay ebuild contract:** unpack the deps tarball onto `${S}` (or equivalent) and **do not** run `bun install` under the sandbox; keep `build.ts --single --skip-install` (and models/`MODELS_DEV_API_JSON` as today).
- **Unpack hygiene:** avoid the current double-unpack of the deps tarball into both `work/` and `${T}/` with a compile-time cache install.
- **Install hygiene (overlay ebuild):** `RESTRICT="strip"` so Portage does not corrupt the Bun-compiled binary; `addwrite` for ftrace when generating shell completions under `sandbox`.
- **Republish / bump:** regenerate deps assets for current opencode PV (and models if still co-required) and prove emerge under default FEATURES including `network-sandbox`.
- **Non-goals:** `RESTRICT="network-sandbox"` as the permanent fix; changing ralph-tui’s cache-based pipeline unless needed for shared helpers; npm/Cargo ecosystems; desktop/Electron packaging; fish completions; inventing CLI PV pins; manager rewriting of `RESTRICT`/`addwrite` (human-owned ebuild install details, specified as overlay contract).

## Capabilities

### New Capabilities

- *(none)* — behavior extends Bun deps packaging and the opencode ebuild contract under existing capabilities.

### Modified Capabilities

- `bun-deps-assets`: opencode (install-tree) packaging of `{pn}-{pv}-deps.tar.xz`; compile-time offline install semantics; ebuild/manager contract that Portage does not re-run registry installs for opencode; install-phase contract (`RESTRICT=strip`, sandbox-safe completions, version reports PV).
- `assets-publish`: only if basename/layout or multi-asset rules change (expected: **same** `deps.tar.xz` basename and multi-asset models pairing; document if tarball top-level entries change).

## Impact

- **Code:** `Update.Bun.Cache` (build/pack path for install-tree vs cache), `Update.Apply.Materialize` opencode path if packaging branches, tests for offline layout.
- **Sibling:** mndz-overlay `dev-util/opencode` ebuild `src_unpack`/`src_compile`; mndz-overlay-assets release assets for opencode PV(s).
- **Operators:** larger deps tarballs for opencode; emerge must succeed with network-sandbox without registry/GitHub access at compile time.
- **Size/time:** full materialize still needs network on the **manager host**; Portage sandbox only sees frozen assets.
