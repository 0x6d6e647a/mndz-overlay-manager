## ADDED Requirements

### Requirement: Deps distfile release assets

When publishing an npm or Bun dependency tarball, the GitHub release asset filename SHALL be `{pn}-{pv}-deps.tar.xz` (overlay package name and PV without revision). Checksum sidecars, assets-repo layout paths, release tag `{pn}-{pv}`, and commit message `category/package: version` SHALL use the same rules as vendor distfiles. Core publish helpers SHALL accept the deps basename without assuming a `-vendor` suffix.

#### Scenario: openspec release asset name

- **WHEN** publishing version `1.4.2` of package name `openspec`
- **THEN** the uploaded release asset name is `openspec-1.4.2-deps.tar.xz` and the release tag is `openspec-1.4.2`

#### Scenario: Lookup deps asset by name

- **WHEN** release `ralph-tui-0.12.0` has asset `ralph-tui-0.12.0-deps.tar.xz`
- **THEN** lookup by that tag and filename succeeds for the reuse path
