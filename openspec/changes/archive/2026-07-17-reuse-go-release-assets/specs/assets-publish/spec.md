## ADDED Requirements

### Requirement: Lookup release by tag and download named asset

The assets/release client SHALL support (via injectable operations suitable for tests) looking up a GitHub release on the assets repository by tag name and, when the release exists, locating an asset by exact filename and downloading its bytes to a caller-chosen path. Lookup SHALL use the configured assets owner/repo and the same authentication token rules as release create when the repository or API requires it. Absence of the release or of the named asset SHALL be reported as a distinct not-found outcome (not as a generic hard failure that implies publish failure).

#### Scenario: Release and asset found

- **WHEN** the assets repo has release tag `beads-1.0.5` with asset `beads-1.0.5-vendor.tar.xz`
- **THEN** lookup by that tag and filename succeeds and download writes the asset body to the requested path

#### Scenario: Missing tag is not-found

- **WHEN** no release exists for tag `beads-9.9.9`
- **THEN** lookup reports not-found without creating a release

#### Scenario: Tag exists but wrong asset name is not-found

- **WHEN** release `crush-0.84.0` exists but has no asset named `crush-0.84.0-vendor.tar.xz`
- **THEN** lookup for that exact asset name reports not-found
