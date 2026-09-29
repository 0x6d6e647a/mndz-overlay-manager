# Proposal

## Why

The overlay's [caddy-analyzer package PR](https://github.com/0x6d6e647a/mndz-overlay/pull/2) adds `net-analyzer/caddy-analyzer` at `0.7.4`, but the manager has no source or update policy for it. Add manager support so `outdated` and `update` can follow upstream releases and maintain the offline Go dependencies.

## What Changes

- Add `net-analyzer/caddy-analyzer` to the canonical policy map with GitHub source `lenny-ts/caddy-analyzer`, tag prefix `v`, and `DepsAndAssets` Go using the repository-root `go.mod`. `L9Lenny/caddy-analyzer` redirects to that canonical repository.
- Limit package runtime lanes to `amd64`, `arm`, and `arm64`, matching the seed's supported architectures. Reuse existing Go candidate selection, release reuse/materialization, Manifest verification, metadata-cache generation, and signed overlay commits.
- Record the `0.7.4` seed contract: build `/usr/bin/caddy-analyze`, inject the version, retain shell completions, test gating, optional firewall dependencies, and the offline GeoIP patch.
- Prepare the donor for updates: use an explicit patch filename instead of `${P}` and reconcile its fork-hosted vendor URL with the configured `assets-path` origin. Retain the patch until an explicit, verified overlay revision removes or replaces it.
- Add package-specific policy, planning, source/asset contract, donor-preservation, and failure-path tests. Document a package-target example without introducing a CLI version argument.

## Capabilities

### New Capabilities

- `net-analyzer-caddy-analyzer-seed`: identity, build/install layout, supported architectures, offline tests, patch references, and asset prerequisites for the caddy-analyzer donor.

### Modified Capabilities

- `update-source`: explicit GitHub source for `net-analyzer/caddy-analyzer`.
- `update-apply`: canonical package policy and its supported runtime-lane architectures.
- `go-vendor-assets`: preserve template-owned build, install, test, and local patch references during Go updates.
- `overlay-test-use`: include caddy-analyzer's offline Go suite in the overlay test convention.

## Impact

- Manager implementation: policy entry, package-focused test fixtures, and a README target example; existing Go apply machinery remains the implementation path.
- Overlay: coordinate with PR #2 for a donor-compatible patch reference and asset origin. Any correction after publication must increase the Portage revision.
- Assets: `caddy-analyzer-<PV>` releases containing `caddy-analyzer-<PV>-vendor.tar.xz` under the configured assets repository, with existing manager checksum-sidecar conventions.
- This delivery creates planning artifacts. Implementation tasks remain unchecked.

## Non-goals

- A new ecosystem, bespoke version planner, new config keys, or CLI version pins. Targets stay `category/package`, unambiguous bare name, or the existing empty-target behavior; the planner selects PVs.
- Re-seeding an older release merely to demonstrate a live update, modifying unrelated packages, or adding caddy-analyzer to the materialize image or overlay wait-edge providers.
- Automatic patch rebasing/removal, upstream self-update invocation, GeoIP database packaging, or running firewall-changing commands as smoke tests.
