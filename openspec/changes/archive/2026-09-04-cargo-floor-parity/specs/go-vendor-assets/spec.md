## MODIFIED Requirements

### Requirement: Reuse existing vendor release when materializing a PV

When materializing a planned `DepsAndAssets Go` PV that needs work, the program SHALL classify its assets release tag `{pn}-{pv}` using the complete required asset set and planned forced-full status. If the release contains every required asset and the PV is not forced full, the program SHALL take the reuse path: it SHALL NOT clone upstream for vendor construction, run `go mod download`, build a new vendor tarball, commit/push assets sidecars, create a release, or re-upload assets for that PV. If the release tag is absent, the program SHALL use the full vendor-and-new-release path.

If the release tag exists but any required asset is absent, or if an existing complete release belongs to a forced-full PV, update SHALL hard-fail the package before disk/image admission because it does not mutate a pre-existing release tag. The classified reuse/full route SHALL be passed into mutation and revalidated before the PV unit; changed release state SHALL hard-fail rather than switch routes.

#### Scenario: Existing release skips vendor and publish

- **WHEN** planned PV `0.84.0` for `crush` needs overlay work, is not forced full, and release `crush-0.84.0` has every required asset including `crush-0.84.0-vendor.tar.xz`
- **THEN** apply does not rebuild the vendor tarball and does not call create-release for that tag

#### Scenario: Missing release uses full path

- **WHEN** planned PV `0.85.0` needs work and release tag `crush-0.85.0` does not exist
- **THEN** apply uses the full clone, vendor, assets publish, and new-release upload path for that PV

#### Scenario: Existing tag missing vendor hard-fails

- **WHEN** release tag `crush-0.85.0` exists but lacks `crush-0.85.0-vendor.tar.xz`
- **THEN** update hard-fails the package before disk/image admission and does not attempt to publish into that tag

#### Scenario: Release route race hard-fails instead of switching

- **WHEN** release state changes between classification and the pre-unit recheck
- **THEN** apply hard-fails that unit instead of changing its admitted reuse/full route
