## Context

See proposal.md for motivation. Overlay `dev-lang/bun-bin` is `GitMvAndManifest`, `SLOT="0"`, one ebuild renamed to upstream latest. Bun consumers get `>=dev-lang/bun-bin-<min>` from a single probed floor. `dev-util/opencode` compiles with whatever `/usr/bin/bun` that floor allows; bun 1.4.2 minify of TypeScript namespaces punches holes in the LayerNode graph. `overlay-atom-closure` already forbids consumer atoms with explicit slots other than omitted/`0`, and GitMv rename-away **hard-fails** on exact pins rather than copying them aside.

Spikes (not in-tree): opencode 1.18.29 compiled with bun 1.3.14 matches official getter emit (`node:()=>` ×127, no `(O||={})`) and answers a prompt; `bun install --frozen-lockfile` succeeds on both 1.3.14 and 1.4.2; current bun-bin `src_install` collides on `/usr/bin/bun`, `bunx`, and `bun` completions if two slots share that layout.

## Goals / Non-Goals

**Goals:**

- Keep latest bun as `/usr/bin/bun` (SLOT=0) while compile-pin PVs remain installable as `bun-${PV}`.
- Manager writes the correct BDEPEND/RDEPEND atoms and GitMv-adds latest instead of renaming a still-required pin.
- Atom closure treats `:0` floors as SLOT=0-only and `=` pins as PV-only.
- Image bun stays latest `:0`.

**Non-Goals:**

- New CLI flags, config keys, or eselect.
- Slotting other GitMv binaries.
- Changing InstallTree/models/strip/webui.
- Compiling opencode in Docker.

## Decisions

### Compile-pin set is InstallTree / `build.ts --compile`

**Choice:** Treat `dev-util/opencode` (InstallTree packaging, `build.ts --compile`) as the compile-pin set. Other Bun packages (ralph-tui) stay floors.

**Why:** That is the failure mode. InstallTree already exists as a per-package packaging mode; a second hardcoded name list would drift.

**Alternative:** Scan ebuild text for `build.ts --compile` at apply time — brittle.

### Exact pin vs minimum are two probe fields

**Choice:** Extend the existing `package.json` probe to return minimum (ceilings, image gate, floor atoms) and exact pin (compile-pin BDEPEND and `bun-${PV}`). Exact pin = `packageManager bun@X.Y.Z` if present, else bare `engines.bun` `X.Y.Z`.

**Why:** Opencode has `packageManager bun@1.3.14` and no winning range; a later package may have `engines.bun: >=1.2.0` plus `packageManager bun@1.3.14`.

**Alternative:** One version string and different atoms per package class — loses the engines-vs-packageManager split.

### SLOT=0 latest; pin `SLOT="${PV}"`; one template

**Choice:** Newest bun-bin ebuild `SLOT="0"`: install `bun-${PV}` plus `bun`/`bunx` symlinks and completions. Kept pins `SLOT="${PV}"`: `bun-${PV}` only. `src_install` branches on `[[ ${SLOT} == 0 ]]`. Debug USE still names the file `bun-${PV}`.

**Why:** Q3.B means compile always calls `bun-${exact}` even when pin == latest. Pin slots must not own unversioned names (collision spike).

**Alternative:** Two templates — more GitMv copy logic. `SLOT="$(ver_cut 1-2)"` — 1.3.15 would replace 1.3.14.

### GitMv add-latest for bun-bin pins only

**Choice:** When renaming bun-bin Old→New would unsatisfy `=dev-lang/bun-bin-Old`, copy/add New as SLOT=0 and rewrite Old’s SLOT to `${Old}`. Other GitMv packages keep rename-away hard-fail (usage/hk).

**Why:** bun-bin is the only slotted GitMv package. General “copy aside” would leave uns slotted duplicates of deno-bin.

**Implementation sketch:** After selecting newest bun-bin ebuild, compute remaining consumer atoms (existing closure parse). If an exact pin equals that newest PV, do not `renameFile`; write a new ebuild path and edit Old `SLOT=`. Shared Manifest/egencache already cover multiple PVs in one directory.

### Floor atoms are `:0`

**Choice:** `>=dev-lang/bun-bin-<min>:0` on BDEPEND and on RDEPEND when it copies BDEPEND. Closure: `:0` matches only bun-bin ebuilds with SLOT=0; `=dev-lang/bun-bin-<PV>` matches that PV any SLOT. Consumer atoms still MUST NOT name pin slots (`:1.3.14`).

**Why:** Unqualified `>=1.3.6` is satisfied by pin 1.3.14; depclean of SLOT=0 would leave ralph without `/usr/bin/bun`. Existing closure already allows explicit slot `0`.

**Alternative:** Virtual/bun — extra package.

### Image bun is `:0` only

**Choice:** Ensure recipe emerges `>=dev-lang/bun-bin-<latest>:0::mndz`. No pin slot in the image.

**Why:** Spike: `bun install --frozen-lockfile` on opencode 1.18.29 succeeded with bun 1.4.2.

## Risks / Trade-offs

- **[Risk] GitMv copy vs rename staging** → Mitigation: commit must stage new ebuild, rewritten old ebuild (not as deletion), Manifest, md5-cache. Tests for add-keep vs rename-delete.
- **[Risk] SLOT rewrite of Old forgotten, two SLOT=0 ebuilds** → Mitigation: after add, Old MUST have `SLOT="${PV}"`; closure/install collision would fail emerge; unit test the rewritten SLOT line.
- **[Risk] `bun-<exact>` missing if SLOT=0 template forgets versioned name** → Mitigation: SLOT=0 always installs `bun-${PV}` (Q3.B); opencode smoke is `which bun-1.3.14` in design tests / operator emerge.
- **[Risk] Atom-closure hard-fail on `:0` if parser treats `:0` as “explicit slot other than 0”** → Mitigation: keep “omitted or 0” allowed; add pin-slot provider exception only on the **ebuild SLOT**, not consumer atoms.
- **[Risk] Next bun-bin GitMv deletes 1.3.14 because prune/GitMv “newest only”** → Mitigation: keep is driven by remaining `=` consumer atoms, not by “old PV”.
- **Trade-off:** Two bun-bin distfiles on disk vs bundling bun 1.3.14 inside the opencode ebuild. Slotting keeps one Bun provider.

## Migration Plan

1. Land manager probe/BDEPEND/GitMv/closure/ensure changes and tests (`hk check`).
2. Overlay: bun-bin template SLOT-conditional install; keep `1.3.14` as pin (`SLOT="1.3.14"`) beside latest `SLOT="0"`; rewrite opencode `BDEPEND`/`src_compile`; ralph `:0`.
3. Operator: `emerge -u bun-bin opencode` pulls both slots; confirm `bun --version` is latest and `opencode --version` is PV.
4. Rollback: revert overlay bun-bin to single SLOT=0 and opencode `>=` would restore the crash; rollback is git revert of overlay + manager, not a Portage slot trick.

## Open Questions

None. Compile-pin detection beyond opencode/InstallTree can wait until a second `--compile` package exists; the spec names the rule and today’s member.
