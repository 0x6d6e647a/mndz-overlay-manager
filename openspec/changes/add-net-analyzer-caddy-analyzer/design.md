# Design

## Context

See `proposal.md` for the requested manager support and companion overlay PR. The manager's hardcoded policy map is the only source of package update policies. Existing root-module Go packages already use `DepsAndAssets (Go Nothing)`, runtime-lane planning, configured assets origins, heavy release reuse verification, package-scoped metadata-cache generation, and signed commits.

The `0.7.4` donor uses the canonical `lenny-ts/caddy-analyzer` repository, requires Go `1.25.13`, and builds `caddy-analyze`. Its vendor release is currently in `airencracken/mndz-overlay-assets`. The companion overlay PR pins its local GeoIP patch filename to `0.7.4` and parameterizes the vendor URL with `${PV}`. These contracts and the chosen assets origin need verification before updater acceptance.

## Goals / Non-Goals

**Goals:**

- Reuse the existing Go update machinery and target resolution with one policy entry.
- Preserve the seed's architecture support, compile/install behavior, and offline regression fix across donor rewrites.
- Establish repeatable fixture-based acceptance for both full materialization and release reuse.

**Non-Goals:**

- A custom caddy-analyzer apply handler, runtime, or release-discovery path.
- Broadening supported architectures without build evidence, inventing a first-install path, or changing unrelated package policies.
- An automatic patch lifecycle or modifications to the full quality-gate policy.

## Decisions

### Policy and architecture scope

Add a `policyArches` entry in `Update.Hardcoded` for GitHub `lenny-ts/caddy-analyzer`, prefix `v`, `DepsAndAssets (Go Nothing)`, and `amd64`, `arm`, `arm64`. This preserves the seed's supported architectures while using existing per-arch Go ceilings. An unrestricted entry would admit other Go architectures that the seed has not validated; a custom planner would duplicate existing behavior.

`Update.Targets.resolveTargets` remains the target resolver. Both the qualified key and an unambiguous `caddy-analyzer` token select the same inventory package. Candidate tags and their root `go.mod` requirements select PVs; `0.7.4` is seed context rather than a CLI pin. No image recipe or overlay wait-edge change is needed.

### Prepare the donor instead of adding patch automation

Use the explicit literal patch basename `caddy-analyzer-0.7.4-offline-geoip.patch` in the donor. Existing Go rewrite logic already preserves non-owned body text; add focused regression coverage with the actual seed shape, including its multiline `SRC_URI` and explicit `${PV}` vendor URL. Freeze the local patch reference, not the package or vendor version.

Coordinate this adjustment with overlay PR #2 before publication when possible. A content-only correction after publication requires `-rN`. If upstream incorporates or changes the affected code, an explicit reviewed overlay revision verifies and removes/replaces the patch. A manager that blindly deletes patches would lose the offline regression fix; package-specific rebasing is outside this proposal.

### Keep one configured assets origin

Treat `assets-path` origin as authoritative. Before updater acceptance, either keep the fork as the configured origin and verify its sidecars, or mirror the seed release and sidecars to the upstream assets repository and update the donor URL in the coordinated overlay change. Both routes obey the same product contract; neither requires hardcoding an owner in the manager.

Use release `caddy-analyzer-<PV>` and asset `caddy-analyzer-<PV>-vendor.tar.xz`. Full materialization uses the existing container, root module cache, hermetic tar/xz rules, and publisher. Complete existing releases use the existing host reuse path and digest verification. Do not rebuild or overwrite an existing release merely to make acceptance convenient. Frozen donor URLs or `${P}` forms must become the existing fully parameterized `${PV}` URL shape for the configured origin.

### Test the policy and the apply contract

Extend the existing Tasty domain modules and their injectable HTTP/process/git runners; do not create a parallel test harness. Include:

- Policy/source/arch assertions and qualified/bare target resolution.
- Fake GitHub release/tag and `go.mod` responses, supported-arch lane selection, and image-Go requirements.
- Full and reuse routes with the exact release/asset names, URL origin, top-level `go-mod/`, sidecar digests, Manifest digests, and metadata-cache paths.
- Donor preservation, including patch file/reference, version injection, completion code, test configuration, and optional-dependency notices.
- Mutation checks for wrong source, wrong technique, unrestricted arches, omitted patch, and mismatched digest; property tests for target alias equivalence and allowed keyword sets.
- Failure and atomicity checks ensuring invalid tags, missing module data, digest mismatches, and release-route races cannot report success or create an overlay success commit.

Use synthetic candidate versions in fixtures to prove an update without changing the real seed PV or requiring a newer live release. Runtime smoke uses safe CLI operations and synthetic logs with GeoIP downloads disabled; it does not run firewall commands or self-update.

## Risks / Trade-offs

- [Risk] A published donor still derives the patch filename from `${P}`. → Prepare it before accepting automated bumps and verify reference resolution in fixtures.
- [Risk] A later upstream tag no longer accepts the retained patch. → Verify patch applicability and the offline suite for the target tag before publishing the updated ebuild; make an explicit overlay revision when removing it.
- [Risk] The seed release exists only in the fork while acceptance uses an upstream assets checkout. → Verify the chosen origin, release, sidecars, donor URL, and hashes together before the update smoke.
- [Risk] Host Go is newer than the Gentoo lane ceilings. → Keep PV selection tree-owned and enforce the existing materialize-image Go check only where required.

## Migration Plan

1. Review this proposal alongside overlay PR #2, and prepare its patch reference and chosen asset origin.
2. Implement the manager policy, fixture coverage, and a README package-target example. Leave shared CLI/config and pipeline behavior intact.
3. Validate source resolution and planning using injected candidate tags. Exercise full and reuse apply flows in isolated temporary overlay/assets repositories.
4. Verify the prepared seed and any real planned update with strict OpenSpec validation and the full `hk check` gate before implementation delivery.
5. Merge/scrub the delta specs into living source-of-truth specs and archive only after implementation tasks and gates are complete.

Rollback the manager policy and tests independently of the overlay seed. Revert any donor correction using the overlay's revision policy; leave immutable published releases available for already-published ebuilds.
