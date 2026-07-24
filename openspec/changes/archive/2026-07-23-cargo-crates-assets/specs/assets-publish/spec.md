## ADDED Requirements

### Requirement: Crates tarball assets use same publish spine

When publishing a Cargo crates distfile `{pn}-{pv}-crates.tar.xz`, the program SHALL use the same checksum sidecars layout, signed assets commit message form `category/package: version`, git push, and GitHub release upload behavior as for Go vendor and npm/Bun deps distfiles, with release tag `{pn}-{pv}` and asset basename `{pn}-{pv}-crates.tar.xz`.

#### Scenario: mise crates release asset name

- **WHEN** assets publish completes for `dev-util/mise` at PV `2026.7.5`
- **THEN** the GitHub release tag is `mise-2026.7.5` and the uploaded asset basename is `mise-2026.7.5-crates.tar.xz`

#### Scenario: Sidecars under category package

- **WHEN** publishing `hk-1.50.0-crates.tar.xz` for `dev-util/hk`
- **THEN** sidecars are created under `dev-util/hk/` in the configured assets worktree
