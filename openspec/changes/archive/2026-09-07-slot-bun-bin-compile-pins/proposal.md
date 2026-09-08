## Why

Emerging overlay `dev-util/opencode` with host `dev-lang/bun-bin` 1.4.2 produces a binary that crashes in `SystemPrompt.environment` (`TypeError: undefined is not an object (evaluating 'a.name')`). The same 1.18.29 tree compiled with bun **1.3.14** (upstream `packageManager`) and the official GitHub linux-x64 build both work. Overlay-manager treats `packageManager bun@1.3.14` as a **floor** (`>=dev-lang/bun-bin-1.3.14`) and GitMv **renames** the single `SLOT="0"` bun-bin ebuild to latest, so the compile toolchain and `/usr/bin/bun` cannot coexist.

## What Changes

- **bun-bin slots:** Latest PV is `SLOT="0"` and installs `bun-${PV}` plus unversioned `bun`/`bunx` symlinks and completions. Each compile-pin PV that must remain is `SLOT="${PV}"` and installs **only** `/usr/bin/bun-${PV}` (no `bunx`, no completions).
- **Compile-pin vs floor atoms:** Bun packages whose Portage compile is `build.ts --compile` / `bun --compile` (today `dev-util/opencode`) get `BDEPEND="=dev-lang/bun-bin-<exact>"` and invoke `bun-<exact>`. Runtime/floor consumers (ralph-tui) get `>=dev-lang/bun-bin-<min>:0` so they cannot be satisfied by a pin slot that has no `/usr/bin/bun`.
- **Probe:** Distinguish **exact pin** (`packageManager bun@X.Y.Z` when that is the compile pin, else a bare `engines.bun` `X.Y.Z`) from **minimum** (`>=` / other parseable floors). `engines.bun` still wins as a *minimum* when parseable; compile-pin exact prefers `packageManager` if present.
- **GitMv bun-bin:** When latest must move and the current newest PV is still required as an exact pin, **add** the new PV as `SLOT="0"` and **rewrite** the old ebuild to `SLOT="${PV}"` instead of renaming it away. Unreferenced old PVs still go away. Rename-away hard-fail remains for non-slotted GitMv packages (e.g. usage exact pins).
- **Materialize image:** Still emerges overlay bun-bin **latest `:0` only**. `bun install --frozen-lockfile` for opencode 1.18.29 succeeds on bun 1.4.2.
- **Docs:** README `update` / bun-bin wait-edge text matches add-and-keep pins, not “rename-away hard-fail” for bun-bin compile pins.

## Capabilities

### New Capabilities

- *(none)* — slot layout, atoms, probe, and GitMv keep extend existing Bun and apply surfaces.

### Modified Capabilities

- `bun-deps-assets`: bun-bin slot/install contract; compile-pin vs floor BDEPEND atoms; probe exact vs minimum; opencode compile invokes `bun-<exact>`; host/image Bun gate still uses the **minimum** for `bun install`.
- `update-apply`: bun-bin GitMv adds latest and rewrites a kept pin’s SLOT instead of renaming it away when an exact pin would otherwise be unsatisfied.
- `overlay-atom-closure`: bun-bin compile-pin keep is add-and-slot, not rename-away hard-fail; reverse-dep keep understands `=` pins and `:0` floors.
- `ensure-materialize-image`: image recipe bun-bin atom is slot-qualified `:0` (latest unversioned bun).

## Impact

- **Manager:** Bun probe types and BDEPEND rewrite (`Update.Bun.Cache`, `Update.EbuildEdit`, adequacy); bun-bin GitMv add/keep/SLOT rewrite (`Update.Apply`); atom-closure keep and GitMv guard; ensure recipe bun-bin `:0`; tests for probe, BDEPEND atoms, GitMv add-vs-rename, closure keep.
- **Overlay (sibling):** `dev-lang/bun-bin` ebuild template (SLOT-conditional install); keep `bun-bin-1.3.14` as pin while latest stays 1.4.2; `dev-util/opencode` `BDEPEND` exact + `bun-${PV}` in `src_compile`; `dev-util/ralph-tui` floor atom `:0`.
- **Operators:** `emerge opencode` can pull bun-bin in two slots; `/usr/bin/bun` remains latest; compile uses `bun-1.3.14`. No new CLI subcommand or config key.
- **Quality:** `hk check` on manager; overlay ebuild changes land in mndz-overlay in this same change.

## Non-goals

- `eselect bun`, versioned completions on pin slots, or a second package (`dev-util/bun-bin`).
- Slotting `deno-bin`, `grok-build-bin`, or other GitMv binaries.
- Compiling opencode inside the materialize image, or emerging pin-slot bun-bin in the image solely for `bun install`.
- Shipping official `opencode` prebuilt `-bin` instead of from-source.
- Changing InstallTree / models distfile packaging, `RESTRICT=strip`, or webui IUSE.
- Filing or fixing upstream OpenCode/Bun compiler bugs in this change.
