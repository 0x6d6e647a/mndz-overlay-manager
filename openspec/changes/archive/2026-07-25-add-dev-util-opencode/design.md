## Context

OpenCode (`anomalyco/opencode`) is a Bun monorepo. Production CLI binaries are produced by `packages/opencode/script/build.ts` with Bun.compile (`--single` for host target). Release CI does **not** pass `--skip-embed-web-ui`, so GitHub release binaries (and the untracked local `opencode-bin` experiment) embed the web UI and expose `opencode web`. The npm package `opencode-ai` only redistributes those prebuilts via optional platform packages.

mndz-overlay-manager already supports `DepsAndAssets Bun` for `dev-util/ralph-tui` (clone tag → `bun install --frozen-lockfile` → `{pn}-{pv}-deps.tar.xz` → assets release → overlay apply). Gaps for opencode:

1. Bun probe requires parseable `engines.bun`; opencode publishes only `packageManager: "bun@1.3.14"`.
2. Assets publish/reuse is **one file per release**; opencode also needs a compile-time **models.dev** JSON snapshot (`MODELS_DEV_API_JSON`).
3. Hardcoded policy and many tests/specs still describe unpublished `dev-util/opencode-bin` as GitMvAndManifest.

Sibling repos: overlay ebuild lives in mndz-overlay; assets in mndz-overlay-assets. This design covers manager behavior and the ebuild/assets contract the manager assumes.

## Goals / Non-Goals

**Goals:**

- Ship and automate `dev-util/opencode` as Bun from-source (`DepsAndAssets Bun`).
- Remove all product policy/test/live-spec reliance on `opencode-bin`.
- General Bun probe: `engines.bun` or fallback `packageManager` `bun@X.Y.Z`.
- General multi-asset assets publish/reuse; opencode publishes deps tarball + models JSON.
- Preserve offline emerge: Portage sandbox does not fetch models.dev or npm/bun registries.
- Align ebuild with release product defaults (`+webui`) and correct runtime deps (ripgrep, not bun).

**Non-Goals:**

- npm `opencode-ai` packaging or fish completions (yargs emits bash/zsh only).
- Desktop/Electron package; multiarch beyond `~amd64` for opencode.
- Manager inventing monorepo `src_compile` bodies beyond KEYWORDS/BDEPEND/SRC_URI/PV rewrites already in the Bun path.
- Rewriting OpenSpec archives; changing ralph-tui’s runtime bun RDEPEND pattern for JS packages.

## Decisions

### D1 — From-source Bun (Shape C), not npm or prebuilt

**Choice:** `GitHub anomalyco/opencode` + `DepsAndAssets Bun`; ebuild compiles with `build.ts --single --skip-install`.

**Alternatives:** npm `opencode-ai` redistributor (heavy optional ELF cache, no engines.node); keep GitMv prebuilt `-bin` (no rebuild, wrong package name story).

**Rationale:** Matches Nix `opencode.nix` and Arch naming (`opencode-bin` vs bare `opencode`); rebuildable; reuses Bun assets pipeline.

### D2 — Remove `opencode-bin` entirely

**Choice:** Delete untracked overlay tree; drop policy entry; retarget GitMv exemplars to `deno-bin` / `grok-build-bin` / `bun-bin`.

**Rationale:** Never published to origin; conflicts with the product name we want.

### D3 — Bun requirement: engines then packageManager

**Choice:** Probe order:

1. Parseable `engines.bun` (`X.Y.Z`, optional `v`, or `>=X.Y.Z`) → that minimum.
2. Else `packageManager` matching `bun@X.Y.Z` (ignore build metadata after version if present) → `X.Y.Z` as minimum.
3. Else hard-fail plan/materialize for that candidate.

**Alternatives:** opencode-only floor; ebuild-only pin without manager probe.

**Rationale:** General, matches Corepack-style monorepos; enables opencode without permanent special cases.

### D4 — Multi-asset publish/reuse (general)

**Choice:** Extend release create/upload to **N assets** under one tag `{pn}-{pv}`. Reuse succeeds only if **every** required basename is present. One signed assets commit may stage sidecars for all distfiles of that PV. On any upload failure after create, best-effort delete the release.

**Alternatives:** separate release tags per file; fold models into deps tarball (rejected — automated separate distfile).

**Rationale:** Forward-compatible; opencode is first consumer; reuse already keys by exact asset name.

### D5 — Models distfile naming and fetch

**Choice:**

- Basename: `{pn}-{pv}-models.json`
- Full materialize: `GET https://models.dev/api.json` → write that file (raw body)
- Sidecars under `{category}/{package}/` like other distfiles
- Ebuild `SRC_URI` always includes models URL; compile sets `MODELS_DEV_API_JSON` to the distfile

**Rationale:** ~3 MB; reproducible; independent of bun-cache; always required (not gated on `webui`).

### D6 — Opencode required asset set

**Choice:** For `dev-util/opencode` materialize/reuse, required assets are:

1. `{pn}-{pv}-deps.tar.xz`
2. `{pn}-{pv}-models.json`

Other Bun packages remain single-asset (deps only) unless extended later.

**Implementation sketch:** package-specific (or small table) “extra distfiles” next to ecosystem default kind; prefer a tiny generic “additional assets” list over a fourth ecosystem kind if only models needs it.

### D7 — Ebuild contract (overlay)

```
IUSE="bash-completion +webui zsh-completion"
KEYWORDS="~amd64"
BDEPEND=">=dev-lang/bun-bin-<probed>"
RDEPEND="sys-apps/ripgrep"   # not bun — compiled ELF
SRC_URI: github archive + deps + models (assets release)

src_compile:
  MODELS_DEV_API_JSON=${DISTDIR}/${PN}-${PV}-models.json
  bun install --frozen-lockfile --cache-dir ${T}/bun-cache
  cd packages/opencode
  if use webui; then
    bun --bun ./script/build.ts --single --skip-install
  else
    bun --bun ./script/build.ts --single --skip-install --skip-embed-web-ui
  fi

src_install: dobin dist binary; optional completions:
  SHELL=/bin/bash opencode completion
  SHELL=/bin/zsh  opencode completion
```

**Rationale:** `+webui` matches release binaries; manager only rewrites bun-bin **BDEPEND** (existing behavior); RDEPEND stays ebuild-owned.

### D8 — Lanes / ceilings

**Choice:** Standard Bun lanes against overlay `dev-lang/bun-bin` (1.3.14 already present). Opencode KEYWORDS remain `~amd64` (package cap).

**Rationale:** No special-case lane disable; host/packageManager floor already satisfiable.

### D9 — Implementation sequence

1. **Bootstrap overlay 1.18.4** (manual or one-shot): ebuild, deps+models assets release, Manifest, md5-cache; delete local opencode-bin.
2. **Manager change** implementing this design (policy, probe, multi-asset, tests, specs).
3. **`update opencode` → 1.18.5** as first automated proof.

Manager work may land before or after bootstrap, but apply against a real inventory needs the ebuild present.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| Monorepo `bun install` cache very large | Accept size; freeze lockfile; same pattern as ralph but heavier |
| models.dev fetch fails during materialize | Hard-fail PV; no partial release; operator retries |
| Partial release (deps without models) | Reuse requires **all** required names; full republish |
| Host bun &lt; packageManager | Host gate on full path (existing); lanes filter by ceilings |
| Fish users expect completions | Document yargs limitation; no fake fish USE |
| `ensureBunBdepend` rewrites any `dev-lang/bun-bin` line | Keep bun-bin only on BDEPEND in ebuild |
| Multi-asset API regression for single-asset packages | Keep single-file call path as list-of-one |

## Migration Plan

1. Remove `opencode-bin` from manager policy/tests/live specs in the same change as opencode enablement.
2. Overlay: delete untracked `dev-util/opencode-bin/`; add `dev-util/opencode`.
3. Assets: create `opencode-1.18.4` release with both files; later manager owns bumps.
4. Rollback: revert manager commit; overlay package can remain hand-maintained without automation.

## Open Questions

None blocking implementation. Optional later: generalize “extra assets” table beyond opencode; optional `test` USE; arm64 KEYWORDS when desired.
