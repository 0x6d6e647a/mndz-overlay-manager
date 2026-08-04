## Why

After Autolith is seeded at 0.17.2 and multiarch probe is green (or waived), mndz-overlay-manager still has no policy or SBCL ecosystem. Registering `dev-util/autolith` as `DepsAndAssets` with a new **Sbcl** ecosystem enables automated version bumps (smoke target **0.18.0**), runtime-lane planning against Gentoo `dev-lisp/sbcl`, and offline deps materialization in Haskell (replacing the seed-time Python helper as the system of record for apply).

## What Changes

- Add `EcosystemSpec` / technique support for **Sbcl** under `DepsAndAssets` (alongside Go, Npm, Bun, Cargo).
- **Requirement probe:** read `sbcl.version` at each candidate tag as a **floor** (semver); lane admit when floor ≤ Gentoo `dev-lisp/sbcl` ceiling for arch×tier.
- **Ceilings:** discover from gentoo repo `dev-lisp/sbcl` non-live ebuilds (same machinery as other runtime-lanes; labels use `dev-lisp/sbcl`).
- **Hardcoded policy:** `dev-util/autolith` → GitHub `luciusmagn/autolith`, tag prefix `v`, `DepsAndAssets Sbcl`.
- **Materialize:** full-path build of `autolith-${PV}-deps.tar.xz` (`.qlot/` + fff with cargo vendor) in Haskell (or tightly orchestrated host tools with preflight); publish/reuse under assets-path like other ecosystems. Seed `autolith-make-deps-tarball.py` may remain as a human fallback; apply path SHALL NOT require it.
- **Ebuild rewrite:** preserve seed template body (`src_*`, private prefix, identity stamp, network-disable, test USE); rewrite KEYWORDS (tilde-only, planned arches), SBCL BDEPEND/RDEPEND floor atom, and deps assets `SRC_URI` with `${PV}`.
- **Exact-set prune** and multi-PV lane collapse per existing `runtime-lanes` / update-apply rules.
- Operator acceptance: `update` for autolith (expect 0.17.2 → 0.18.0 when upstream allows), emerge new PV, `autolith --version`.

## Non-goals

- Creating the initial 0.17.2 ebuild or first deps tarball (belongs to `seed-dev-util-autolith`).
- Multiarch QEMU probe (belongs to `probe-autolith-multiarch`).
- Overlay package of `dev-lisp/sbcl` or keywording arm64.
- Changing Autolith upstream to drop exact version checks (seed stamps at build; manager does not patch author intent beyond what seed already encodes).
- Shell completions.
- Implementing a general Gentoo multiarch `testing` command product (future).

## Capabilities

### New Capabilities

- `sbcl-deps-assets`: SBCL/Autolith-style DepsAndAssets materialize, distfile naming, requirement probe from `sbcl.version`, preflight tools, and ebuild field ownership for SBCL floor atoms.

### Modified Capabilities

- `deps-assets`: Extend `DepsAndAssets` ecosystem inventory to include Sbcl; distfile suffix remains `-deps.tar.xz` with Autolith layout contract.
- `runtime-lanes`: SBCL ceiling source from gentoo `dev-lisp/sbcl`; lane labels name `dev-lisp/sbcl`; floor comparison uses `sbcl.version` probe.
- `update-apply`: Hardcoded policy map includes `dev-util/autolith` as `DepsAndAssets Sbcl`; template preservation for non-assets ebuild body across SBCL apply rewrites.
- `update-command` / `outdated-command` (as needed): operator-facing examples or inventory scenarios if they enumerate ecosystems/packages.
- `project-docs`: Document any new host tools required for SBCL materialize (e.g. sbcl, git, qlot/quicklisp path) in README/CONTRIBUTING when product surface changes.

## Impact

- **mndz-overlay-manager**: Types, Hardcoded, Runtime.Ceilings, Deps plan/materialize, EbuildEdit, Preflight, tests, delta specs, docs.
- **mndz-overlay / assets**: mutated when operator runs `update` for autolith (0.18.0 ebuild + deps asset).
- **Depends on**: completed `seed-dev-util-autolith`; recommended completed or waived `probe-autolith-multiarch`.
- **Operator**: manager update + emerge + `autolith --version` on the new PV.
