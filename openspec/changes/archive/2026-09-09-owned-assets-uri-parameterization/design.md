## Context

See `proposal.md` for motivation. Write already owns tags via `packageAssetsTag` in `parameterizeAssetsSrcUri` (`${PV}` infix or `{pn}-` prefix) and leaves `rusty-v8-…` alone. Adequacy uses `assetsSrcUriParameterized :: Text -> Bool`, which requires `${PV}` in **every** path after `mndz-overlay-assets/releases/download/`. Codex’s second assets URL uses `rusty-v8-${RUSTY_V8_VER}`. `ebuildNeeds*` call that predicate without `pn`. Tests for Codex SRC_URI cover write preservation, not adequacy.

Pin-keyed harvest stays `isCodexKey`; this design does not add a companion-record framework.

## Goals / Non-Goals

**Goals:**

- One ownership helper used by rewrite and by adequacy.
- Thread overlay PN into content-fix helpers that currently only see ebuild text.
- Fail closed on PN vs `rusty-v8` prefix collision (policy map + rewrite/adequacy).
- Tests: Codex two-URL body is adequate; frozen `{pn}-<pv>` still is not; colliding PN is rejected.

**Non-Goals:**

- Plan-time lock `v8` pin vs `RUSTY_V8_VER` adequacy.
- Literal `rusty-v8-150.4.0` vs `${RUSTY_V8_VER}` as its own content-fix (write already rewrites that on full-path via `ensureCodexV8Overlay`).
- Dummy Portage category or GitHub tag rename.
- Harvest for any package except `dev-util/codex`.
- CLI/config/docs surface.

## Decisions

1. **Share `packageAssetsTag`; do not denylist `rusty-v8-` in the `${PV}` predicate.** Alternative: `segmentParameterized` true if path contains `${PV}` or `rusty-v8-` — rejected; next pin-keyed identity repeats the Codex false positive. Ownership is “this overlay package’s `{pn}-` tag,” which write already uses.

2. **`assetsSrcUriParameterized` takes `pn`.** Alternative: keep `Text -> Bool` and infer ownership without PN — rejected; the membership test needs `{pn}-`. Adequacy already has `pn`. Thread it through `ebuildNeedsContentFix`, `ebuildNeedsContentFixAtom`, `ebuildNeedsCargoBodyFix`, and `ebuildNeedsCargoContentFix`. Call sites in `Update.Adequacy` pass `pn`; tests that construct those helpers pass a name.

3. **Collision is string prefix on `{pn}-` vs `{identity}-`, identity `rusty-v8`.** Alternative: parse `{pn}-{pv}` grammar — rejected; write does not parse versions, and check must not invent a stricter grammar. Alternative: test-only guard — rejected; rewrite/adequacy must not rewrite a colliding tag if a PN slips in. Policy-map check is a unit test over `hardcodedPolicies`; runtime hard-fail is the same helper when a tag is reserved-identity-shaped and would otherwise be treated as owned.

4. **Harvest remains `PackageKey` `dev-util/codex`.** Alternative: start a `PinCompanion` record now — rejected until a second consumer exists (same decision as `codex-rusty-v8-harvest`). Spec states the generalization shape so the next messy package does not add another SRC_URI special case.

5. **No layer-2 pin snapshot.** A Codex PV bump with a new `v8` pin is a missing crates tag and already full-path harvests. Crates-reuse with a moved pin is not a realistic Codex path.

## Risks / Trade-offs

- [A stray `dolt-2.1.6` assets URL inside a crush ebuild is ignored] → accepted; it is not crush-owned. Frozen crush URLs still flag.
- [Literal `rusty-v8-150.4.0` looks adequate for parameterization] → accepted; full-path `ensureCodexV8Overlay` still templates `${RUSTY_V8_VER}`. Not a same-PV loop.
- [PN `rusty` would own `rusty-v8-…` without the collision helper] → fail closed; current mapped PNs do not collide.
- [Threading `pn` through Go/Npm/Bun/Sbcl content-fix is extra API] → those ecosystems only have package-owned assets URLs today; behavior stays the same if `pn` is correct.

## Migration Plan

1. Shared ownership + collision helpers; `assetsSrcUriParameterized pn`; thread `pn`; tests; `hk check`.
2. Merge spec deltas into living `deps-assets`, `outdated-command`, `cargo-crates-assets`.
3. No overlay `-rN` and no assets republish; `outdated codex` should print nothing when 0.153.4 is otherwise adequate.
4. Rollback: revert the predicate to “every URL has `${PV}`” (Codex same-PV lines return).

## Open Questions

None.
