## Why

`outdated` reports `dev-util/codex 0.153.4 -> 0.153.4` on both rust lanes with `[assets reusable]` after `update` has already written that PV. The ebuild is current: KEYWORDS `-* ~amd64`, `RUST_MIN_VER="1.95.0"`, empty `CRATES`, crates URL `codex-${PV}/…`, Manifest DIST present. Adequacy still treats **every** `mndz-overlay-assets` download URL as a package-PV asset and requires `${PV}` in the path. The rusty-v8 snapshot URL is pin-keyed (`rusty-v8-${RUSTY_V8_VER}`), so the check never goes true. Write already leaves non-`{pn}-` tags alone. Same check/write skew as the usage `6.4.1 -> 6.4.1` floor mismatch, different field.

## What Changes

- **Parameterization is package-owned tags.** Check and write share one ownership test: an assets-host release tag belongs to this overlay package when it already contains `${PV}` or starts with `{pn}-`. Owned tags (and their filenames that start with `{pn}-`) MUST use `${PV}`. Other assets-host tags are a different version axis; `${PV}` does not apply to them and they are not a content-fix.
- **Fail closed on PN vs pin-identity prefix collision.** Overlay package names must not prefix-collide with reserved pin identities (today `rusty-v8`): `{pn}-` prefix of `rusty-v8-`, the reverse, or equal names. Detect over the hardcoded policy map and at rewrite/adequacy so a future PN such as `rusty` cannot own `rusty-v8-150.4.0`.
- **Keep rusty_v8 harvest Codex-shaped.** Full-path harvest stays gated on `dev-util/codex`, not “lock has v8”. Spec calls out that a second messy package generalizes to a pin-keyed companion record rather than another SRC_URI special case.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `deps-assets`: shared content assessment’s “parameterized asset SRC_URI” means package-owned assets-host tags only.
- `outdated-command`: same-PV Codex with a pin-keyed rusty-v8 URL is not a content-only gap.
- `cargo-crates-assets`: write and check use the same ownership test; PN vs `rusty-v8` collision fails closed; harvest remains Codex-only with a next-consumer note.

## Impact

- **Behavior**: `outdated` / `update` reach a steady current state for `dev-util/codex` at 0.153.4; hk/mise/usage/dolt and other package-PV-only ebuilds keep flagging frozen `{pn}-<literal-pv>` URLs; a future overlay PN that collides with `rusty-v8` cannot ship.
- **Code**: `Update.EbuildEdit` (`assetsSrcUriParameterized` takes `pn`, shared ownership helper with `parameterizeAssetsSrcUri`, collision helper); `Update.Adequacy` / `ebuildNeeds*` thread `pn`; `Update.Hardcoded` (or tests over it) for policy-map collision; Codex-shaped body tests that currently only cover write also assert adequacy.
- **Non-goals**: no plan-time `v8` lock-pin snapshot or “lock pin always wins on crates reuse” (unrealistic for Codex: new pin is a new PV and a missing crates tag, which is already full-path harvest); no dummy Portage category or assets tag rename; no `${PV}` on rusty-v8 URLs; no denylist of `rusty-v8-` inside the `${PV}` predicate; no layer-2 pin-template adequacy (`rusty-v8-150.4.0` literal vs `${RUSTY_V8_VER}`) in this change; no harvest for packages other than `dev-util/codex`; no CLI, config, or README/CONTRIBUTING/AGENTS surface change.
