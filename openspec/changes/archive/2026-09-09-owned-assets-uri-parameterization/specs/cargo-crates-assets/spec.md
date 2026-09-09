## MODIFIED Requirements

### Requirement: rusty_v8 submodule sidecar

When full-path Cargo materialize runs for `dev-util/codex` and that unit’s provenance lock pins a crates.io `v8` package, the program SHALL treat a rusty_v8+recursive-submodules snapshot as a required pin-keyed companion **separate from** the Codex crates release. Full-path SHALL: (1) parse the `v8` name/version/checksum from the provenance lock; (2) if mndz-overlay-assets already has basename `rusty-v8-${ver}-with-submodules.tar.xz` **and** GitHub release tag `rusty-v8-${ver}` provides that asset, and downloaded bytes verify against the assets-worktree checksum sidecars, reuse it without cloning; (3) otherwise clone `https://github.com/denoland/rusty_v8` at tag `v${ver}` with recursive submodules inside the materialize container, pack under the hermetic tar/xz rules, and publish a new assets release whose tag, GitHub release name, and asset basename are keyed by crate version (`rusty-v8-${ver}` / `rusty-v8-${ver}-with-submodules.tar.xz`), not by Codex PV. The program SHALL write overlay `RUSTY_V8_VER` and the rusty-v8 `SRC_URI` download tag from that pin. The program SHALL NOT pack this tree into `{pn}-{pv}-crates.tar.xz`. The program SHALL NOT attach the snapshot to GitHub release tag `codex-${PV}`. Chromium clang and rust-toolchain GCS objects SHALL remain ebuild `SRC_URI` distfiles, not overlay-assets.

A package other than `dev-util/codex` SHALL NOT harvest or require this sidecar, including other Cargo GitTag packages whose lock might pin crates.io `v8`. Harvest SHALL remain gated on overlay package `dev-util/codex`, not on the presence of a crates.io `v8` pin in an arbitrary Cargo lock. A second overlay package that needs a pin-keyed assets companion SHALL introduce a named companion record (identity, pin source, ebuild assignment, harvest, consumers) rather than a package-specific exception in package-PV SRC_URI parameterization.

Codex crates required-asset lookup for tag `codex-${PV}` SHALL be `{pn}-{pv}-crates.tar.xz` only. Absence of a rusty_v8 snapshot SHALL NOT make an existing crates release partial.

#### Scenario: Same v8 pin reuses the snapshot

- **WHEN** full-path materialize runs for `codex` 0.153.4 and the lock still pins `v8` `150.4.0` and assets already hold `rusty-v8-150.4.0-with-submodules.tar.xz` under tag `rusty-v8-150.4.0` with verifying checksums
- **THEN** apply does not clone `denoland/rusty_v8`
- **AND** it still publishes `{pn}-0.153.4-crates.tar.xz` as a new crates sidecar
- **AND** the written ebuild `RUSTY_V8_VER` is `150.4.0`
- **AND** rusty-v8 `SRC_URI` still downloads from tag `rusty-v8-150.4.0`

#### Scenario: Pin change harvests a new snapshot

- **WHEN** full-path materialize runs for `dev-util/codex` whose lock pins `v8` `150.5.0` and no rusty_v8 snapshot exists for `150.5.0`
- **THEN** the container clones tag `v150.5.0` with recursive submodules
- **AND** it publishes `rusty-v8-150.5.0-with-submodules.tar.xz` on GitHub release tag `rusty-v8-150.5.0` whose release name is `rusty-v8-150.5.0`
- **AND** the written ebuild `RUSTY_V8_VER` is `150.5.0`

#### Scenario: hk is unaffected

- **WHEN** full-path materialize runs for `dev-util/hk`
- **THEN** apply does not harvest or require a rusty_v8 snapshot

#### Scenario: Missing snapshot does not partial the crates tag

- **WHEN** release tag `codex-0.153.4` has `codex-0.153.4-crates.tar.xz` and no rusty-v8 asset
- **THEN** that crates tag is complete for Codex crates reuse/full-path classification
- **AND** rusty-v8 is looked up on tag `rusty-v8-${ver}` instead

## ADDED Requirements

### Requirement: Package-owned assets URI parameterization for Cargo

When rewriting or assessing Cargo ebuild assets `SRC_URI`, the program SHALL use the package-owned tag rule from `deps-assets`. Write SHALL rewrite only package-owned mndz-overlay-assets release tags and `{pn}-` filenames to `{pn}-${PV}`. Write SHALL NOT retag `rusty-v8-…` as `codex-${PV}` (or any other overlay `{pn}-${PV}`). Adequacy SHALL require `${PV}` only on package-owned assets URLs. A Codex ebuild whose crates URL uses `codex-${PV}` and whose rusty-v8 URL uses tag `rusty-v8-${RUSTY_V8_VER}` SHALL be adequate for asset URI parameterization.

#### Scenario: Codex crates and rusty-v8 URLs together are adequate

- **WHEN** a `dev-util/codex` ebuild has `…/download/codex-${PV}/codex-${PV}-crates.tar.xz` and `…/download/rusty-v8-${RUSTY_V8_VER}/rusty-v8-${RUSTY_V8_VER}-with-submodules.tar.xz`
- **THEN** asset URI parameterization does not need work
- **AND** write leaves the rusty-v8 release tag unrewritten to `codex-${PV}`

#### Scenario: Frozen crates URL still needs work

- **WHEN** a Cargo ebuild has `…/download/hk-0.50.0/hk-0.50.0-crates.tar.xz` and no `${PV}`
- **THEN** asset URI parameterization needs work

### Requirement: Overlay PN vs pin-identity collision

The program SHALL fail closed when an overlay package name prefix-collides with a reserved pin-keyed assets identity. The reserved identity for the rusty_v8 snapshot is `rusty-v8`. Collision is any of: overlay PN equals the identity; `{pn}-` is a prefix of `{identity}-`; `{identity}-` is a prefix of `{pn}-`. The hardcoded policy map SHALL NOT contain a colliding PN. Rewrite and adequacy SHALL hard-fail rather than treat a colliding tag as package-owned.

#### Scenario: Current overlay PNs do not collide with rusty-v8

- **WHEN** the hardcoded policy map is checked against identity `rusty-v8`
- **THEN** no overlay PN collides (`codex`, `hk`, `mise`, `usage`, `biodiff`, and the other mapped names)

#### Scenario: Hypothetical rusty package is rejected

- **WHEN** an overlay package PN `rusty` would be rewritten or assessed against a `rusty-v8-150.4.0` assets tag
- **THEN** the program hard-fails the collision instead of rewriting that tag to `rusty-${PV}`
