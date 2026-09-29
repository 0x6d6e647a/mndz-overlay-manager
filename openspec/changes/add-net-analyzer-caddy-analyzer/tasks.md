# Tasks

## 1. Coordinate the existing overlay donor

- [ ] 1.1 Inspect overlay PR #2 and the chosen assets checkout. Record whether acceptance uses the fork or a verified upstream mirror; verify the assets origin, seed release `caddy-analyzer-0.7.4`, vendor archive, checksum sidecars, and donor URL agree. Do not overwrite an existing release tag to complete missing assets.
- [ ] 1.2 Prepare the donor's explicit `${FILESDIR}/caddy-analyzer-0.7.4-offline-geoip.patch` reference and existing `${PV}` vendor URL convention. Coordinate the original PR before publication where possible; otherwise publish a content-only revision bump with matching Manifest and md5-cache. Verify source extraction and patch application still succeed for `0.7.4`.
- [ ] 1.3 Add or retain seed checks for the binary version, completion flag combinations, malformed arguments, offline JSON reports, and unavailable-GeoIP interval reporting. Verify all checks and the patched upstream Go suite pass with external downloads disabled; confirm removing the GeoIP fix makes its regression test fail.

## 2. Add policy and planning coverage

- [ ] 2.1 Add `net-analyzer/caddy-analyzer` to `Update.Hardcoded` as GitHub `lenny-ts/caddy-analyzer`, prefix `v`, `DepsAndAssets (Go Nothing)`, using `policyArches` for `amd64`, `arm`, and `arm64`. Extend `test/Test/Policy.hs`; verify policy, source, root-module location, and exact architecture assertions pass.
- [ ] 2.2 Extend existing target and planner tests with a temporary inventory containing the prepared seed and synthetic GitHub candidates. Verify qualified and unambiguous bare targets resolve identically, empty targets retain their current semantics, unsupported tokens hard-fail, PV selection obeys permitted tree lanes, and a newer host Go does not widen the plan.
- [ ] 2.3 Add fake-HTTP contract cases for canonical release/tag requests and root `go.mod` responses, including `go 1.25.13`, invalid tags, malformed module data, and fetch failures. Verify valid candidates are comparable and errors remain package-scoped without successful apply admission.
- [ ] 2.4 Add property and mutation checks for target alias equivalence, keyword membership within the allowed arch set, and policy regressions. Verify a wrong GitHub owner, a `GitMvAndManifest` technique, or a removed arch allowlist makes the relevant tests fail.
- [ ] 2.5 Add a README example using `outdated caddy-analyzer` and `update net-analyzer/caddy-analyzer` with the existing operator prerequisites. Verify the commands match current CLI help and introduce no version argument or new config key.

## 3. Verify full and reuse apply behavior

- [ ] 3.1 Add a prepared-donor fixture and package-specific full-path integration case using existing injectable runners. Verify clone tag, repository-root module cache, required Go version, `caddy-analyzer-<PV>-vendor.tar.xz` naming and `go-mod/` layout, configured asset origin, existing sidecar/release contracts, Manifest digests, package md5-cache, and package-scoped signed overlay commit.
- [ ] 3.2 Add a complete-release reuse integration case. Verify it downloads and validates the existing vendor archive without vendor clone, `go mod download`, Docker admission, release creation, or upload; the output ebuild and Manifest match the reused bytes.
- [ ] 3.3 Assert donor preservation on both routes with its multiline `SRC_URI`, parameterized asset URL, literal patch reference and retained file, `CGO_ENABLED=0`, version injection, binary name, completion code, test USE/RESTRICT, temporary test config, licenses, and optional firewall notices. Verify a synthetic PV bump still resolves the patch filename; do not add automatic patch management.
- [ ] 3.4 Add adversarial and atomicity integration cases for unavailable release assets, sidecar or Manifest digest mismatches, release-route changes after classification, too-old image Go, and failed overlay commands. Verify each hard-fails without an overlay success commit or success line, uses existing retained-workspace/orphan-asset diagnostics, and does not weaken immutable-release behavior. Verify digest and patch-preservation mutations are caught.

## 4. Integration acceptance and source-of-truth completion

- [ ] 4.1 Verify the prepared seed's install and safe smoke commands: version, help, all completions, synthetic JSON analysis, and interval reporting without GeoIP downloads. If a real update is planned, repeat after that update; otherwise use the synthetic integration bump rather than publishing an older seed solely for demonstration. Do not invoke self-update or firewall-changing commands.
- [ ] 4.2 Run `openspec validate add-net-analyzer-caddy-analyzer --type change --strict` and the full `hk check` pipeline. Verify both exit zero before marking implementation tasks complete or shipping the implementation.
- [ ] 4.3 Merge the five capability deltas into living `openspec/specs/` using the repository's sync/archive workflow after implementation acceptance. Verify modified requirements retain unrelated existing scenarios, the new capability has a real Purpose, and source-of-truth text has no placeholders or residual change language; run `openspec validate --all --strict`.
- [ ] 4.4 Update the companion overlay PR's description and linked manager delivery to reflect the final reviewed implementation, with verification claims matching the completed tasks. Verify the overlay package, assets origin, local patch reference, and manager policy agree, then archive only when every implementation task and gate is complete.
