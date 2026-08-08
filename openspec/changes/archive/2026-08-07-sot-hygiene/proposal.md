## Why

Living OpenSpec source of truth (`openspec/specs/`) has accumulated change-delta residue, multi-homed package-policy lists that drift from code, and a `test-coverage` domain that records implementation waves instead of durable product rules. That wastes agent context and risks wrong package policy. A specs-only hygiene pass fixes it while product behavior stays unchanged.

## What Changes

- Scrub living SoT of forbidden residue phrases (“after this change”, “as part of this change”, Wave-N / residual program language that is not product-visible).
- Single-home the hardcoded package policy map: canonical list only in `update-apply`; other domains point there or use package-specific scenarios without restating the full map.
- Align `deps-assets` (and any thinned Go policy bullets) with `src/Update/Hardcoded.hs` — include `dev-db/badger` and `dev-util/opencode`.
- Remove the duplicate standalone `dev-util/autolith` policy requirement in `update-apply` (keep one canonical entry).
- Collapse `test-coverage` from wave/residual archaeology into a short durable set (engine, isolation rows, excludes, reports, entrypoint, no floors, surface coverage categories).
- Thin `go-vendor-assets` and `go-tree-lanes` of rules already owned by `deps-assets` / `runtime-lanes` / `update-apply` (keep Go-specific materialize, ceilings, and `go.mod` selection).
- Prefer “program/CLI” subjects over “library SHALL provide …” and drop helper-name pins where requirements currently name internal APIs.

## Non-goals

- No product behavior, CLI, config, or apply-path code changes.
- No new ecosystems, packages, or policy entries beyond making specs match existing `Hardcoded.hs`.
- No rename of the `go-vendor-assets` directory/capability path.
- No moving seed/overlay-only domains out of this repo (decision deferred).
- No archive cleanup of historical changes or probe logs.
- No numeric coverage floors or ratchet policy.
- No `hk check` / quality-pipeline policy changes (docs only if a scrub forces a false statement — expected none).

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `overlay-test-use`: Remove “this change” / “after this change” wording from scenarios and requirements; keep permanent overlay test USE/RESTRICT/revbump rules.
- `ssh-agent-session`: Permanent rule for not rewriting assets SSH remotes to HTTPS token URLs (drop “as part of this change”).
- `update-apply`: Canonical package policy list only; drop duplicate autolith-only requirement; ensure list matches hardcoded map (including badger, opencode, cargo usage subdir, autolith).
- `deps-assets`: Stop restating a partial policy map (or fix it to full set and defer to `update-apply`); keep technique/naming/spine; include badger/opencode if any minimal list remains for scenarios.
- `go-vendor-assets`: Remove duplicated DepsAndAssets constructor + full hardcoded Go package list; keep Go-only materialize/SRC_URI/BDEPEND/reuse edges; scenarios may still name packages without owning policy.
- `go-tree-lanes`: Keep Go ceiling discovery and `go.mod` lane targets; defer exact-set prune and shared KEYWORDS collapse to `runtime-lanes` / `update-apply` instead of restating.
- `test-coverage`: Replace Wave-1…N / residual / floor-free-per-wave requirements with durable coverage capability requirements (no floors once; surface categories once).
- `ebuild-version`: Rephrase library/API-shaped requirements to program/observable PV parse/render/compare behavior (drop `comparePV` name pin if present as requirement subject).
- `cli-activity` / `update-command` (light): Rename “phase-one” progress requirement titles/text to permanent phase naming where residue-only.

## Impact

- **Specs only:** deltas under this change; living SoT after apply/archive merge.
- **Code:** none required (behavior already matches intended canonical policy).
- **Docs:** none expected (`project-docs` surfaces unchanged).
- **Validation:** `openspec validate --change sot-hygiene` and post-merge `openspec validate --specs`; banned-phrase `rg` on living specs.
- **Agents:** smaller, consistent SoT for future changes.
