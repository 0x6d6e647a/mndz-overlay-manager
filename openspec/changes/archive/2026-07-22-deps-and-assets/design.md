## Context

`update` already automates Go packages via `GoVendorAndAssets`: temp clone → vendor tarball → assets publish → overlay rewrite → Manifest SHA512 verify → signed commit, with multi-PV planning from Gentoo `dev-lang/go` ceilings. Shared assets publish is explicitly forward-compatible with `-deps.tar.xz`.

npm (`dev-util/openspec`) and Bun (`dev-util/ralph-tui`) already have:

- Hardcoded sources (`Npm` registry / GitHub tags)
- Overlay ebuilds consuming `{pn}-{pv}-deps.tar.xz` from mndz-overlay-assets
- Maintainer Python scripts for cache tarballs (reference only; **not** runtime dependencies)

They remain `Unsupported "… deps assets"`. This design unifies language deps under one technique and generalizes lanes so BDEPEND and KEYWORDS follow the same ceiling × requirement model as Go.

Constraints: project quality gates (`hk check`); shell-out for `go`/`npm`/`bun`/`git`/`tar`/`xz`/`ebuild` is acceptable; pure Haskell multi-hash; GPG option B; overlay auto-push out of scope; live ebuilds out of scope.

## Goals / Non-Goals

**Goals:**

- One technique `DepsAndAssets EcosystemSpec` (`Go` | `Npm` | `Bun`) replacing `GoVendorAndAssets`
- Shared apply spine: plan → reuse or build → publish → overlay → verify → commit
- Haskell materializers for npm-cache and bun-cache (script parity, no Python)
- Runtime-lane engine: ceilings from **all arches** on the runtime package’s KEYWORDS; Go/Node/Bun ceiling sources; candidate set = overlay non-live ∪ upstream newer than max overlay
- Full overlay content: SRC_URI `${PV}`, KEYWORDS from lanes, BDEPEND from probed req, Manifest adequacy
- Enable openspec + ralph-tui; preserve Go behavior under the new type (plus multi-arch KEYWORDS)

**Non-Goals:**

- Live/`9999` ebuilds (ignore/don’t touch if present)
- First import of empty package dirs (hard-fail without non-live local PV)
- npm git-only clone+install
- Cargo CRATES
- Complex semver `engines` ranges beyond minimum forms
- Deleting overlay Python helpers
- Automatic backfill of older-than-overlay upstream versions

## Decisions

### Decision: Technique model (Option B, big-bang)

```text
UpdateTechnique
  = GitMvAndManifest
  | DepsAndAssets EcosystemSpec
  | Unsupported Text

EcosystemSpec
  = Go { goModSubdir :: Maybe FilePath }
  | Npm
  | Bun
```

| Package | Source | Technique |
|---------|--------|-----------|
| dolt | GitHub | `DepsAndAssets (Go (Just "go"))` |
| beads, crush | GitHub | `DepsAndAssets (Go Nothing)` |
| openspec | `Npm "@fission-ai/openspec"` | `DepsAndAssets Npm` |
| ralph-tui | GitHub | `DepsAndAssets Bun` |
| cargo pkgs | … | still `Unsupported` |
| bin packages | … | `GitMvAndManifest` |

**Npm identity:** package string lives only on `UpdateSource.Npm`; technique is bare `Npm`. Apply hard-fails if source is not `Npm`.  
**Bun / Go:** require `GitHub` source (same as today’s Go).

Alternatives: keep `GoVendorAndAssets` forever + parallel npm techniques — rejected (two spines). Parallel first without Go rename — rejected by product choice (big-bang).

`techniqueNeedsAssets` is true for all `DepsAndAssets`.

### Decision: Shared apply spine

Per planned PV unit (after runtime-lane plan):

1. Require ≥1 non-live local ebuild for the package (else hard-fail: not first-import)
2. Needs-work if missing ebuild, content fix (SRC_URI / BDEPEND / KEYWORDS), Manifest missing deps/vendor DIST, or exact-set prune
3. **Reuse** if assets release `{pn}-{pv}` has expected asset filename; else **full** build+publish
4. Overlay mutate → `ebuild … manifest` → SHA512 verify → signed overlay commit (commit-on-unit-success)
5. After all planned PVs succeed → exact-set prune extras (non-live only; leave live untouched)

```text
                    runtime-lane plan
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
         REUSE path                FULL path
    download asset              materialize tarball
    no host lang gate           host runtime ≥ req
    no assets critical sec      publish assets (locked)
              │                         │
              └────────────┬────────────┘
                           ▼
              SRC_URI / KEYWORDS / BDEPEND
              ebuild manifest + SHA512
              overlay commit
```

### Decision: Distfile naming (always overlay PN)

| Kind | Filename |
|------|----------|
| Go | `{pn}-{pv}-vendor.tar.xz` top-level `go-mod/` |
| Npm / Bun | `{pn}-{pv}-deps.tar.xz` top-level `npm-cache/` or `bun-cache/` |

Release tag remains `{pn}-{pv}`. Never use npm scope segment (`@fission-ai/…`) in asset names. Layout helper generalizes `vendorTarballName` → distfile name by kind.

SRC_URI form:

`https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/{pn}-${PV}/{pn}-${PV}-deps.tar.xz`  
(or `-vendor` for Go)

### Decision: Materializers (Haskell only)

**Go** (existing): clone tag → `GOMODCACHE=…/go-mod go mod download -modcacherw` → tar `go-mod/`.

**Npm (registry-only):**

1. `npm pack {npmPackage}@{pv}` in temp dir  
2. `npm --cache <tmp>/npm-cache install <tgz>`  
3. `XZ_OPT=-T0 -9 tar -acf {pn}-{pv}-deps.tar.xz npm-cache`  

No git clone. Future: git-only packages.

**Bun:**

1. Temp clone GitHub at `prefix+pv` (like Go)  
2. Require `bun.lock` at repo root; hard-fail if missing  
3. `bun install --frozen-lockfile --cache-dir <tmp>/bun-cache`  
4. Tar top-level `bun-cache/` as `{pn}-{pv}-deps.tar.xz`  

### Decision: Runtime lanes (generalized; revises Go arches)

Replace hard-coded `{amd64,arm64}×{plain,tilde}` with arches **discovered from the runtime package’s non-live ebuilds’ KEYWORDS**.

| Ecosystem | Runtime package | Ceiling repo |
|-----------|-----------------|--------------|
| Go | `dev-lang/go` | gentoo (`portageq get_repo_path / gentoo`) |
| Npm | `net-libs/nodejs` | gentoo |
| Bun | `dev-lang/bun-bin` | **overlay** (`mndz-overlay-path`) |

For each arch token found (strip `~`; ignore `-*`):

- **plain ceiling** = max runtime PV whose KEYWORDS include bare arch  
- **tilde ceiling** = max runtime PV whose KEYWORDS include `~arch` or bare arch  

Lanes = arch × {plain, tilde}. Empty plain ceilings (overlay `~*` only, e.g. bun-bin) → tilde-only lanes; collapse still yields one ebuild with `~amd64 ~arm64` typically.

**Lane target:** max package PV among candidates with parseable req ≤ ceiling (same comparison spirit as Go host/req gates).

**KEYWORDS assembly:** per arch, bare if any plain lane targets PV; else `~arch` if tilde targets; else omit. **Package KEYWORDS are defined by the plan** (all runtime arches that participate)—revises Go’s amd64/arm64-only ownership.

**Labels:** `(dev-lang/go amd64)`, `(net-libs/nodejs ~loong)`, `(dev-lang/bun-bin ~arm64)`, etc.

**Unsatisfiable lane:** no target for that lane (Go-like). **Zero planned PVs overall** → hard-fail plan.

**Exact-set prune:** after all planned PVs succeed, remove non-live ebuilds not in the planned set; never touch live.

### Decision: Candidate versions

```text
if no non-live local ebuild:
  hard-fail (first import / empty dir not supported; live-only does not count)
else:
  candidates = non-live local PVs
             ∪ { upstream PV | PV > max(non-live local PVs) }
```

No automatic older-than-overlay backfill. If tip’s req exceeds all ceilings and no older local exists that fits, lanes may be empty → zero PVs → hard-fail (operator must intervene).

Upstream listing:

- Go/Bun: comparable GitHub tags (existing), filtered to candidate set  
- Npm: registry versions filtered to candidate set (not full history unless overlay empty—which we forbid)

### Decision: Requirement probes and BDEPEND

| Eco | Probe | Unparseable / missing | BDEPEND atom |
|-----|-------|----------------------|--------------|
| Go | `go.mod` `go` directive | keep existing skip/gate rules for go.mod | `>=dev-lang/go-<v>:=` |
| Npm | `engines.node` from registry metadata (or packed package.json) | **hard-fail plan** for that package | `>=net-libs/nodejs-<v>[npm]` |
| Bun | `engines.bun` from `package.json` at tag | **hard-fail plan** | `>=dev-lang/bun-bin-<v>` |

Atom rewrite (shared `replaceAtomsInText`) must drop the full prior atom tail: version, optional slot (`:=` / `:slot`), and full USE bracket `[…]` **including flag names**. Stopping after `[` leaves residual `npm]` and produces invalid Portage metadata (`[npm]npm]`), which broke openspec-style `RDEPEND="…[npm]"` / `BDEPEND="${RDEPEND}"` ebuilds.

**engines minimum parse (v1):** `>=X.Y.Z`, bare `X.Y.Z`, optional leading `v`. Complex ranges (`^`, `||`, `<`, `*`) → unparseable → hard-fail (R2: surface need to improve parser).

Host gate (full path only): host `go`/`node`/`bun` version ≥ req before materialize. Reuse: no host language gate.

### Decision: Outdated / update reporting

All `DepsAndAssets` use lane-labeled multi-line reporting (generalize “Go tree-lane” requirements to “runtime-lane”). `GitMvAndManifest` stays single-line latest.

### Decision: Preflight

Always on `update`: `git`, `ebuild`, `egencache`, `gpg` (existing).

When any selected package will attempt `DepsAndAssets` full or assets work: `xz`, assets path, token, SSH readiness as today.

Additionally:

- Go full-path in scope → `go` on PATH  
- Npm full-path in scope → `npm` on PATH  
- Bun full-path in scope → `bun` on PATH  

Reuse-only work does not require the language tool (mirror Go reuse). Host vs req is not spine preflight.

### Decision: Spec / module layout

| Spec | Role |
|------|------|
| `deps-assets` | Technique, naming, spine, policy enablement |
| `runtime-lanes` | Ceilings, candidates, selection, KEYWORDS, labels, prune |
| `npm-deps-assets` | Registry pack, engines.node, nodejs BDEPEND, openspec |
| `bun-deps-assets` | Clone+bun, engines.bun, bun-bin BDEPEND, ralph |
| `go-vendor-assets` | Go materializer + existing vendor/Manifest rules under new type |
| `go-tree-lanes` | Delta toward runtime-lanes / all arches |

Suggested modules (implementation guidance, not mandatory names):

- `Update.Deps.Types` / spine in `Update.Apply`  
- `Update.Runtime.Lanes` + ceiling discovery (generalize `Update.Go.Tree` / `Lanes`)  
- `Update.Npm.Cache`, `Update.Bun.Cache`  
- Keep `Update.Go.Vendor` wired as Go plugin  

### Decision: Progress labels

Reuse existing multi-progress step model; npm/bun full path steps analogous to Go (e.g. pack/install/compress vs clone/mod download/compress). Reuse path keeps download → rewrite → manifest sequence.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Multi-arch KEYWORDS rewrite narrows/widens openspec vs hand list | Intentional: plan owns KEYWORDS from nodejs arches; document in design/README |
| `engines` hard-fail noisy if packages omit engines | Explicit R2; fix parser or add engines upstream; better than silent wrong BDEPEND |
| Candidate set misses older-than-overlay under tight ceiling | Documented; hard-fail zero PV; no silent wrong latest |
| Big-bang Go rename churn in tests/specs | Mechanical rename + keep behavior tests; archive deltas carefully |
| Large nodejs KEYWORDS arch set → many lanes | Collapse still limits unique PVs; arches without ceilings contribute nothing |
| npm registry rate limits when probing many versions | Candidate set is small (local + newer only); cache probes where useful |
| Bun only in overlay | Ceiling path is overlay; clear error if `dev-lang/bun-bin` missing |

## Migration Plan

1. Land types + naming helpers + runtime-lane generalization with Go still the only consumer behind `DepsAndAssets Go`  
2. Wire npm then bun materializers and policy  
3. Update tests: rename `GoVendorAndAssets`, multi-arch fixtures, openspec/ralph unit tests with injected runners  
4. Operator: ensure `npm`/`bun` on PATH when updating those packages; no config schema break beyond technique behavior  
5. Overlay Python scripts remain; optional later deprecation outside this change  

Rollback: revert change; overlay assets/ebuilds remain valid; manual Python path still works.

## Open Questions

None blocking. Deferred products: live ebuilds, first import, npm git-only, cargo, complex engines ranges.
