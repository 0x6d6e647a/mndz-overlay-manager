## Context

Seed delivers a template ebuild at 0.17.2 and `autolith-make-deps-tarball.py`. Probe validates multiarch packaging. Support teaches mndz-overlay-manager to plan and apply Autolith like other `DepsAndAssets` packages, with a new **Sbcl** ecosystem.

Author rule: build SBCL ≡ run SBCL ≡ sources (seed stamps at emerge). Manager treats upstream `sbcl.version` as a **floor** for lane selection and BDEPEND `>=dev-lisp/sbcl-${floor}:=[source]` (or equivalent atom form matching the seed template).

Upstream tags: `v0.17.2` (seed), `v0.18.0` (first automated target). Same SBCL floor 2.6.4 on both; mcparen git ref changes between them → deps tarball must refresh on bump.

## Goals / Non-Goals

**Goals:**

- `DepsAndAssets Sbcl` end-to-end: outdated gaps, update apply, deps materialize/publish/reuse, KEYWORDS/BDEPEND rewrite, exact-set prune.
- Hardcoded policy for `dev-util/autolith`.
- Preserve seed ebuild body (identity stamp, private prefix, network-disable, cores, test USE).
- Operator smoke: update to 0.18.0, emerge, `autolith --version`.

**Non-Goals:**

- Re-doing seed from scratch; multiarch QEMU productization.
- Overlay SBCL package.
- Replacing Gentoo `[source]` with bundled 2.6.4.

## Decisions

### 1. Ecosystem shape

```haskell
-- conceptual
DepsAndAssets (Sbcl)  -- no go.mod subdir field needed
```

- **Update source:** `GitHub "luciusmagn" "autolith" "v"`.
- **Distfile:** `{pn}-{pv}-deps.tar.xz` (same suffix as npm/bun deps naming family).
- **Release tag:** `{pn}-{pv}`.
- **Layout contract** (seed-compatible): top-level `.qlot/` + `fff/` with cargo `vendor/`.

### 2. Requirement probe

- Fetch/read `sbcl.version` at candidate tag (raw file at repo root).
- Parse as dotted numeric version; unparseable → skip candidate for lane selection (same hardness as unparseable go.mod).
- Compare floor ≤ lane ceiling with existing PV comparison rules.

### 3. Ceilings and labels

- Ceiling directory: gentoo `dev-lisp/sbcl` via `portageq get_repo_path / gentoo` (not overlay unless later needed).
- Non-live ebuilds only; plain/tilde per arch from KEYWORDS.
- Labels: `(dev-lisp/sbcl amd64)` / `(dev-lisp/sbcl ~riscv)` style per runtime-lanes.
- Planned KEYWORDS for overlay ebuilds: **tilde-only** tokens for arches that select a PV.

### 4. Materialize (Haskell system of record)

Full path when assets missing/mismatch:

1. Clone GitHub tag for PV.
2. Produce `.qlot/` (host needs SBCL + qlot/quicklisp bootstrap—preflight documents tools).
3. Fetch fff at `native/fff/commit`, `cargo vendor`.
4. Pack `autolith-${PV}-deps.tar.xz`.
5. Publish to assets-path + GitHub release (existing assets-publish multi-asset-capable path).

Reuse path when release asset SHA matches (no rematerialize).

Seed Python helper may remain for humans; apply MUST work without invoking it.

### 5. Ebuild rewrite / preservation

Manager may rewrite:

- Filename PV
- KEYWORDS
- SBCL version atom in BDEPEND/RDEPEND (`>=dev-lisp/sbcl-<floor>:=[source]` form)
- Deps assets `SRC_URI` with `${PV}`

Manager MUST preserve:

- Private prefix install logic, wrapper, identity stamp, network-disable, core build, IUSE/test, non-assets SRC_URI companions if any, FILESDIR/PATCHES if present

Mirror the badger jemalloc preservation pattern for “template-owned body.”

### 6. Preflight tools

Document and check as applicable:

- Always for update: git, ebuild, egencache, gpg (existing).
- When materialize needed: `xz`, `git`, `sbcl`, qlot/quicklisp path, `cargo` (for vendor), network.
- When reuse only: no cargo/sbcl for materialize (same spirit as Go reuse skipping `go`).

### 7. Tests

- Unit: probe parse, ceiling discovery for sbcl fixtures, policy lookup, ebuild rewrite preserve body, plan floor vs ceiling.
- Integration as needed with fake GitHub/assets.

### 8. Docs

- README: tools for Autolith/SBCL packages; technique inventory includes Sbcl.
- CONTRIBUTING/AGENTS only if agent process changes (unlikely).

## Risks / Trade-offs

- **[Risk]** Qlot materialize is heavier than go mod download → **Mitigation:** reuse aggressively; document host setup; optional later containerize materialize.
- **[Risk]** Template drift on rewrite → **Mitigation:** preserve tests like jemalloc companion.
- **[Risk]** All historical tags share floor 2.6.4 → multi-PV lanes rare until pin moves → **Mitigation:** infrastructure still correct; single-PV collapse OK.
- **[Risk]** Stable Gentoo SBCL &lt; 2.6.4 → zero lanes on stable-only → **Mitigation:** expected; testing keywords needed.

## Migration Plan

1. Implement Sbcl ecosystem + policy + tests; `hk check`.
2. Operator: `update` autolith (or targeted outdated/update).
3. Emerge 0.18.0; `autolith --version`.
4. Optionally note Python helper as fallback-only in overlay README.

## Open Questions

- Exact preflight binary names for qlot (system package vs bootstrap script)—decide at implement from seed helper experience.
- Whether `:=[source]` USE-dep syntax is written exactly as seed or split across DEPEND/RDEPEND—match seed template.
