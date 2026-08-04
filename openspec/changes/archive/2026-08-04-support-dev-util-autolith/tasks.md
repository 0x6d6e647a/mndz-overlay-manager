## 1. Types and policy

- [x] 1.1 Extend `EcosystemSpec` / technique wiring with `Sbcl` under `DepsAndAssets`
- [x] 1.2 Add hardcoded policy for `dev-util/autolith` (GitHub `luciusmagn/autolith`, tag `v`, `DepsAndAssets Sbcl`)
- [x] 1.3 Update policy/inventory tests that enumerate ecosystems or hardcoded keys

## 2. Ceilings, probe, and planning

- [x] 2.1 Discover gentoo `dev-lisp/sbcl` ceilings (reuse Runtime.Ceilings patterns)
- [x] 2.2 Probe `sbcl.version` floor at candidate tags; compare floor ≤ ceiling for lane targets
- [x] 2.3 Lane labels use `dev-lisp/sbcl`; tilde-only KEYWORDS collapse per runtime-lanes
- [x] 2.4 Unit tests for probe parse, ceilings fixtures, and floor-vs-ceiling selection

## 3. Materialize, publish, rewrite

- [x] 3.1 Implement full-path materialize: clone tag → `.qlot/` + fff vendor → `autolith-${PV}-deps.tar.xz`
- [x] 3.2 Wire assets publish/reuse for `-deps.tar.xz` layout; preflight tools for materialize vs reuse
- [x] 3.3 Ebuild rewrite: SBCL floor atom, deps `SRC_URI` with `${PV}`, KEYWORDS; **preserve** seed template body
- [x] 3.4 Exact-set prune and apply integration for Sbcl packages
- [x] 3.5 Unit/integration tests for rewrite preservation and materialize/reuse dispatch

## 4. Specs and quality

- [x] 4.1 Keep delta specs aligned (`sbcl-deps-assets`, `deps-assets`, `runtime-lanes`, `update-apply`, `project-docs`)
- [x] 4.2 Update README (and CONTRIBUTING if needed) for Sbcl materialize host tools
- [x] 4.3 Run `hk check` and fix failures

## 5. Operator smoke

- [x] 5.1 Run manager `update` for `dev-util/autolith` (expect bump 0.17.2 → 0.18.0 when upstream allows)
- [x] 5.2 Confirm new ebuild retains seed template structure and new deps asset exists
- [x] 5.3 Emerge the new PV and run `autolith --version`
- [x] 5.4 Report smoke results; mark complete only after smoke passes
