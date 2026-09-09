## 1. Ownership and collision helpers

- [x] 1.1 Lift the write-side package-owned tag test (`${PV}` infix or `{pn}-` prefix) into a shared helper used by both `parameterizeAssetsSrcUri` and adequacy; verify existing parameterization tests still rewrite `{pn}-<literal-pv>` and still leave `rusty-v8-…` untagged as `codex-${PV}`
- [x] 1.2 Change `assetsSrcUriParameterized` to take overlay PN and require `${PV}` only on package-owned assets-host tags; verify a Codex-shaped body with `codex-${PV}` crates URL plus `rusty-v8-${RUSTY_V8_VER}` is parameterized-true, and a frozen `hk-0.50.0` crates URL is still false
- [x] 1.3 Add a prefix-collision helper for overlay PN vs reserved identity `rusty-v8` (`pn == identity`, `{pn}-` prefix of `{identity}-`, or the reverse); verify current `hardcodedPolicies` PNs do not collide, and PN `rusty` collides with `rusty-v8`

## 2. Adequacy plumbing

- [x] 2.1 Thread overlay PN through `ebuildNeedsContentFix`, `ebuildNeedsContentFixAtom`, `ebuildNeedsCargoBodyFix`, and `ebuildNeedsCargoContentFix` into the parameterized-URI check; verify Go/Npm/Bun/Sbcl/Cargo call sites in `Update.Adequacy` and tests compile and still flag frozen package-owned URLs
- [x] 2.2 Hard-fail rewrite/adequacy when a tag would be treated as package-owned but collides with `rusty-v8`; verify a test that PN `rusty` plus tag `rusty-v8-150.4.0` fails closed instead of rewriting to `rusty-${PV}`
- [x] 2.3 Extend Codex SRC_URI tests so the two-URL ebuild is not `ebuildNeedsCargoBodyFix` / content-only outdated; verify `testCargoEmptyCratesSrcUri` (or a dedicated case) asserts adequacy true, and a CheckPlan-style Cargo present-PV with that body is `Ok` not `0.153.4 -> 0.153.4`

## 3. Specs and quality

- [x] 3.1 Merge delta specs into living SoT (`deps-assets`, `outdated-command`, `cargo-crates-assets`) and scrub delta residue; verify `openspec validate --strict`
- [x] 3.2 Confirm README/CONTRIBUTING/AGENTS need no updates (no operator CLI/config, quality pipeline, or agent-process change)
- [x] 3.3 `hk check` green (build, tests, ormolu, hlint, stan, weeder)
