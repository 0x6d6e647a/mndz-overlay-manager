## Why

Overlay `dev-util/opencode-2.0.3` is a git-mv of the v1 donor. Upstream 2.x moved the CLI from `packages/opencode` to `packages/cli`, renamed `--skip-embed-web-ui` to `--skip-web-ui`, and dropped yargs `completion`. Emerge dies at `cd packages/opencode`. The manager rewrote `BDEPEND` to `=dev-lang/bun-bin-1.4.2` but left `bun-1.3.14` in `src_compile`, and still requires a models.dev companion distfile that v2 no longer uses at compile time.

## What Changes

- **Overlay `opencode-2.0.3-r1`:** Compile/install/test against `packages/cli`; invoke `bun-1.4.2`; `--skip-web-ui` when `-webui`; install `dist/cli-*/bin/opencode`; Effect `--completions bash|zsh|fish` (add `fish-completion` IUSE); wrapper sets `OPENCODE_DISABLE_AUTOUPDATE=1`; drop models `SRC_URI` / `MODELS_DEV_API_JSON`; keep `OPENCODE_DISABLE_MODELS_FETCH=1` only in Portage phases; `OPENCODE_CHANNEL=prod`; `NODE_OPTIONS=--max-old-space-size=4096` at compile; keep `IUSE=test` and live `src_test` (known ACP subprocess failures are not skipped).
- **Overlay `bun-bin-1.4.2-r1`:** Revbump the SLOT=0 template that already installs `bun-${PV}` so Portage rebuilds installs that still have a fat `/usr/bin/bun` and no `bun-1.4.2` (the Sep 7 in-place edit of 1.4.2 had no revision).
- **Manager compile-pin rewrite:** On overlay apply, rewrite compile-pin ebuild bodies so invocations of `bun-<old>` become `bun-<exact>` (not BDEPEND-only).
- **Manager fail-closed guard:** After clone, hard-fail the PV if the ebuild `cd` target or `script/build.ts` under that cwd is missing from the tag. Do not guess a replacement path.
- **Drop models companion:** Opencode required assets are deps-only. Stop fetching `models.dev`, stop publishing `{pn}-{pv}-models.json`, stop requiring it for reuse. Leave the existing `opencode-2.0.3-models.json` GitHub asset unused. Runtime may fetch `https://models.opencode.ai`; do not bake `OPENCODE_DISABLE_MODELS_FETCH` into the installed wrapper.
- **No assets `-r1`:** Reuse `opencode-2.0.3-deps.tar.xz` as published.

## Capabilities

### New Capabilities

- *(none)* — ebuild contract, compile-pin rewrite, clone-time guard, and models-companion removal extend existing Bun / assets / overlay-test surfaces.

### Modified Capabilities

- `bun-deps-assets`: opencode ebuild contract (v2 paths, `bun-<exact>` rewrite on apply, `--skip-web-ui`, completions, channel, wrapper, no models distfile); clone-time cwd + `build.ts` hard-fail; stop models companion fetch/publish.
- `assets-publish`: opencode required release set is deps-only; reuse of `opencode-${PV}` succeeds with deps alone; extra unused models.json on an old tag does not block reuse.
- `overlay-test-use`: opencode `src_test` runs from `packages/cli` with `bun-<exact>`; failures are not skipped or `RESTRICT="test"`-squelched.

## Impact

- **Manager:** `Update.EbuildEdit` (bun invocation rewrite); apply/materialize clone-time path guard; Adequacy / Materialize companion list (drop models); tests and fixtures that assume `packages/opencode` or models.json extras.
- **Overlay (sibling):** `dev-util/opencode-2.0.3-r1.ebuild` + Manifest/md5-cache; `dev-lang/bun-bin-1.4.2-r1.ebuild` + Manifest/md5-cache.
- **Assets GitHub:** no new release and no deletion required.
- **Operators:** `emerge =dev-util/opencode-2.0.3-r1` under `network-sandbox` should compile; `/usr/bin/opencode --version` is `2.0.3`; autoupdate is off; `FEATURES=test` emerge currently fails on ACP subprocess tests (accepted). No new manager CLI flags or config keys.
- **Quality:** `hk check` on manager; overlay commits in mndz-overlay in this same change.

## Non-goals

- Auto-rewriting `packages/opencode` → `packages/cli` (or any compile-cwd rename).
- Patching `updater.run()` or disabling `opencode upgrade`.
- Republishing or deleting `opencode-2.0.3-deps.tar.xz` / `opencode-2.0.3-models.json`.
- Making ACP subprocess / standalone tests pass.
- Desktop/Electron package, `opencode2` coexistence binary, or fish as a default IUSE.
- Changing ralph-tui BunCache packaging or bun-bin pin-slot layout beyond the 1.4.2 revbump.
