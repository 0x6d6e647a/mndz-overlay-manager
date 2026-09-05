# Design: crates.io-sourced Cargo packages and dev-util/biodiff seed

## Context

The DepsAndAssets Cargo lane (see `cargo-crates-assets` spec) assumes git-tag provenance: clone the tag, run pycargoebuild against the clone, pack registry crates from the clone's `Cargo.lock`, and rewrite `SRC_URI` to a GitHub archive. biodiff's tagged source tree cannot build with default features (`biodiff-wfa2-sys/build.rs` requires the `WFA2-lib` git submodule that tag archives exclude), while upstream publishes buildable crates.io artifacts: the published `biodiff` crate strips the `[workspace]` table, ships a `Cargo.lock`, and resolves `hexagex`/`biodiff-wfa2-sys` as registry crates whose published forms bundle the WFA2-lib C sources. Verified upstream facts feeding this design: crates.io hosts `biodiff` 1.2.0/1.2.1 and `biodiff-wfa2-sys` `2.3.4-cf3eb92`/`2.3.5` (both bundling WFA2-lib); published crates carry their `Cargo.lock`; git tags `v1.2.x` and registry versions share the same numbers; the materialize image recipe already installs `net-misc/aria2`; `aria2c` with its default User-Agent successfully fetches the crates.io download endpoint (spiked on this host: `biodiff-1.2.0.crate`, 88,532 bytes, exit 0).

## Goals / Non-Goals

**Goals:**

- Add a second Cargo provenance, `CargoCratesIo`, alongside `CargoGitTag`, with coherent behavior across policy, ebuild `SRC_URI`, materialization, packing, and MSRV harvest.
- Ship `dev-util/biodiff` in the overlay at PV 1.2.0 (one release behind latest) with the full upstream-default (bundled WFA2) build available via `+wfa2`, and let `outdated`/`update` drive the 1.2.0 → 1.2.1 bump through the new lane as the acceptance test.
- Keep GitTag lane behavior byte-for-byte identical for hk/mise/usage.

**Non-Goals:**

- No git-submodule-aware source tarball lane; no `build.rs` patching; no system-WFA2 (`sci-libs/wfa2`) packaging or dynamic-link USE variant.
- No plan-time crates.io existence probe; no generic crate-name ≠ PN modeling (divergence hard-fails).
- No new operator CLI surface, config keys, host toolchains, or version/CHANGELOG ritual.
- No second package adopting CratesIo.

## Decisions

1. **Provenance lives on `EcosystemSpec::Cargo` as `cargoSource :: CargoSource` with constructors `CargoGitTag` and `CargoCratesIo`.** Alternative considered: a new ecosystem variant (`CargoCrate`) — rejected because every ecosystem predicate and shared apply/update rule would fork in two; a second alternative, carrying provenance on `UpdateSource`, was rejected because version detection stays GitHub for biodiff (tags ≡ registry versions) and provenance is an apply-lane concern, not a fetch concern. The three existing policies gain the field mechanically.

2. **CratesIo materialize populates the unit `work/src` from the published `.crate` instead of a clone, entirely in-container.** `aria2c` (default User-Agent) fetches `https://crates.io/api/v1/crates/<crate>/<pv>/download`; unpack yields `<p>/` (matches `${P}`); pycargoebuild runs against the unpacked crate root with the same flags as the GitTag lane; pack parses the unpacked crate's `Cargo.lock`. Alternative considered: host-side fetch/unpack — rejected because it splits the hermetic lane across host/container and adds a second host download path. The unit layout, distdir, stage tree, and `temp-workspace` lifecycle are reused unchanged; only the "populate `src`" operation differs, so `CargoOps` gains a fetch-and-unpack op rather than a parallel pipeline.

3. **The ebuild source distfile is the canonical crates.io API form, owned by the manager's `SRC_URI` rewrite.** pycargoebuild still emits a GitHub archive line (it derives from the manifest `repository` field), so the manager overrides the source line per provenance exactly as it already owns the `SRC_URI+=` crates line: GitTag keeps the current form; CratesIo writes `SRC_URI="https://crates.io/api/v1/crates/<crate>/<pv>/download -> <p>.crate"` plus the assets crates line. Alternative considered: `static.crates.io` direct URLs — rejected as less canonical with no functional win. Crate name is read from the working ebuild (pycargoebuild output); divergence from PN hard-fails rather than being parameterized.

4. **Provenance coherence is an apply-time content check.** Policy provenance, ebuild source-line form, and materialize/pack provenance must agree; mismatch hard-fails before Manifest/assets/commit. Alternative considered: detecting the mismatch only at emerge time — rejected because it surfaces after signed commits exist.

5. **No plan-time crates.io probe.** A missing published crate surfaces as a materialize-time unit hard-fail naming the endpoint and PV — the same failure class as a failed tag clone in the GitTag lane. This avoids new plan-phase network surface and check-cache schema changes.

6. **MSRV harvest provenance follows the materialize source.** Tag floor `T(pv)` still probes the GitHub tag (runtime-lanes machinery unchanged). The build-floor source harvest walks the unpacked published crate's active set (its manifest has no in-tree path deps) and registry harvest covers the packed vendor crates — which now includes `hexagex` and `biodiff-wfa2-sys` manifests. Reuse performs no download or harvest, unchanged.

7. **The seed ebuild gates WFA2 with `IUSE="+wfa2"` default-on.** USE on = upstream default features (bundled WFA2); USE off = `--no-default-features` (pure-Rust RustBio backend). Hand-written ebuild content survives pycargoebuild inplace (hk precedent: `BDEPEND`, custom `src_configure`/`src_install` all survive bumps), so the mapping survives manager-driven rewrites without manager awareness of the flag.

8. **One change covers the lane, the policy line, the seed spec, and the smoke choreography.** The seed is the lane's acceptance test; splitting would force a lane-only change with no consumer to verify it. Seed assets are manually materialized in the materialize image following the seed-spec precedent (rulesync), mirroring the lane steps.

## Risks / Trade-offs

- [Upstream tags a release without publishing the matching crate] → materialize hard-fails naming the endpoint and PV; no silent GitTag fallback. Operator recovery is upstream-side; the error is the designed failure surface.
- [pycargoebuild against an unpacked published crate behaves differently than against a clone] → the manual seed materialize exercises the exact flow first; container smoke for the bump; unit tests cover flag parity. cargo publish's standard artifacts (`Cargo.toml.orig`, `.cargo_vcs_info.json`) are already handled by pycargoebuild.
- [crates.io yanks a PV the overlay targets] → the download endpoint still serves yanked crates, so materialization continues to work; if a version disappears entirely, the fetch hard-fail names the URL for diagnosis.
- [Larger vendor tarball for CratesIo (workspace members become registry crates)] → negligible for biodiff (two extra crates; the `-sys` crate with bundled WFA2-lib is a few MB).
- [bindgen-era BDEPEND (llvm-core/clang) carries forward to later PVs that no longer need it] → harmless over-declaration; a content fix with revision bump can drop it.
- [Coherence check false-positives on unusual ebuilds] → the check keys on the two exact source-line forms the manager itself writes; GitTag behavior is unchanged, and mismatch errors name both forms.

## Migration Plan

1. Manager lane: add the provenance field (existing policies updated), lane ops, `SRC_URI` rewrite branch, coherence check, MSRV harvest provenance, tests — gated by `hk check`.
2. Merge spec deltas into `openspec/specs/` (`cargo-crates-assets`, new `dev-util-biodiff-seed`); `openspec validate`.
3. Seed the overlay: write `dev-util/biodiff` 1.2.0 ebuild + `metadata.xml`; manually materialize and publish `biodiff-1.2.0-crates.tar.xz` in the materialize image; `ebuild … manifest`; `gencache`; GPG-signed overlay and assets commits.
4. Acceptance: emerge `=dev-util/biodiff-1.2.0` and smoke `--version`/`--help`; `outdated biodiff` reports `1.2.0 -> 1.2.1`; `update biodiff` applies the bump through the CratesIo lane (publishes `biodiff-1.2.1`); emerge verifies 1.2.1.
5. Rollback: revert the overlay seed commit and the policy line; biodiff returns to `Unsupported` and the manager stops planning it. The lane code is inert for GitTag packages.

## Open Questions

None — all decisions were resolved during exploration (provenance placement, crates.io URI form, aria2c with default User-Agent verified by spike, materialize-time-only failure surface, single-change packaging, no version ritual).