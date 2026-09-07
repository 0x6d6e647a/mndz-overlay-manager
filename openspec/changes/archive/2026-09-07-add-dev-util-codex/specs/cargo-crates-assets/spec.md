## ADDED Requirements

### Requirement: rust-toolchain.toml dotted channel as tag floor

When active-set discovery for a Cargo candidate completes with no `rust-version` declaration, the program SHALL read `rust-toolchain.toml` at the lock root (else the repository root). If that file’s `channel` is a dotted numeric version (optional leading `v`), `T(pv)` SHALL be that normalized three-component version and SHALL take precedence over substituting `"0.0.0"` for rust-version absence. Channel values that are not dotted versions (`stable`, `nightly`, date nightlies, or malformed) SHALL NOT supply a tag floor. Complete absence of both a rust-version and a dotted channel remains explicit tag-floor absence. A malformed `rust-toolchain.toml` that cannot be parsed SHALL fail the plan.

#### Scenario: Codex channel becomes T(pv)

- **WHEN** the active set at tag `rust-v0.153.3` declares no `rust-version` and `codex-rs/rust-toolchain.toml` has `channel = "1.95.0"`
- **THEN** planned tag floor `T(pv)` is `1.95.0`
- **AND** candidate selection does not use `0.0.0` for that PV

#### Scenario: stable channel does not invent a floor

- **WHEN** the active set has no `rust-version` and `rust-toolchain.toml` has `channel = "stable"`
- **THEN** that file does not supply `T(pv)`
- **AND** complete absence rules still apply

### Requirement: rusty_v8 submodule sidecar

When full-path Cargo materialize of a GitTag package’s lock pins a crates.io `v8` package, the program SHALL treat a rusty_v8+recursive-submodules snapshot as a required companion asset keyed by that crate version, not by overlay PV. Full-path SHALL: (1) parse the `v8` name/version/checksum from the provenance lock; (2) if mndz-overlay-assets already has `rusty-v8-${ver}-with-submodules.tar.xz` (or the agreed basename) for that version and bytes verify, reuse it without cloning; (3) otherwise clone `https://github.com/denoland/rusty_v8` at tag `v${ver}` with recursive submodules inside the materialize container, pack under the hermetic tar/xz rules, and publish a new assets release keyed by crate version. The program SHALL NOT pack this tree into `{pn}-{pv}-crates.tar.xz`. The program SHALL NOT key the snapshot on Codex PV. Chromium clang and rust-toolchain GCS objects SHALL remain ebuild `SRC_URI` distfiles, not overlay-assets.

A GitTag package whose lock does not pin crates.io `v8` SHALL NOT grow this sidecar.

#### Scenario: Same v8 pin reuses the snapshot

- **WHEN** full-path materialize runs for `codex` 0.153.4 and the lock still pins `v8` `150.4.0` and assets already hold `rusty-v8-150.4.0-with-submodules.tar.xz`
- **THEN** apply does not clone `denoland/rusty_v8`
- **AND** it still publishes `{pn}-0.153.4-crates.tar.xz` as a new crates sidecar

#### Scenario: Pin change harvests a new snapshot

- **WHEN** full-path materialize runs for a Cargo GitTag PV whose lock pins `v8` `150.5.0` and no rusty_v8 snapshot exists for `150.5.0`
- **THEN** the container clones tag `v150.5.0` with recursive submodules
- **AND** it publishes `rusty-v8-150.5.0-with-submodules.tar.xz`

#### Scenario: hk is unaffected

- **WHEN** full-path materialize runs for `dev-util/hk`
- **THEN** apply does not harvest or require a rusty_v8 snapshot solely because hk is Cargo GitTag

### Requirement: Windows-only git remotes omitted from GIT_CRATES

When writing or repairing `GIT_CRATES` for a Cargo GitTag ebuild, the program SHALL omit git packages that the lock records only as dependencies of `[target.'cfg(windows)'.dependencies]` (or equivalent windows-only target tables) of the active Linux set. `microsoft/mxc` / `appcontainer_common` for Codex SHALL be omitted.

#### Scenario: mxc dumped

- **WHEN** the manager writes `GIT_CRATES` for `dev-util/codex`
- **THEN** the map has no `microsoft/mxc` entry
- **AND** Linux git remotes such as `crossterm` remain

## MODIFIED Requirements

### Requirement: Manager-owned SRC_URI for cargo

After pycargoebuild inplace update on full path (or on content repair), the program SHALL rewrite the ebuild `SRC_URI` to the provenance-appropriate primary source line plus the mndz-overlay-assets crates tarball URL for `{pn}-${PV}-crates.tar.xz`, and SHALL NOT rely on `${CARGO_CRATE_URIS}` as the **registry** dependency distfile source for steady-state tarball-shaped ebuilds. Provenance `CargoGitTag`: the primary source line is the upstream GitHub source archive for the tag. Provenance `CargoCratesIo`: the primary source line is the canonical crates.io download distfile for the policy crate name and PV, `https://crates.io/api/v1/crates/<crate>/<pv>/download -> <p>.crate`.

The program SHALL treat `${CARGO_CRATE_URIS}` as list-era registry URIs **only when `CRATES` is non-empty**. When `CRATES` is empty, the rewrite SHALL preserve `GIT_CRATES` URI expansion (`${CARGO_CRATE_URIS}` as used for git crates) and SHALL preserve extra `SRC_URI` lines that are neither the GitHub/crates.io primary source nor the crates tarball (including rusty_v8 snapshot and Chromium GCS clang/rust-toolchain distfiles). The program SHALL NOT collapse those ebuilds to a two-line github-archive-plus-crates form.

#### Scenario: Assets crates URL present

- **WHEN** the manager rewrites SRC_URI for `dev-util/hk` at PV `1.50.0`
- **THEN** SRC_URI references `hk-1.50.0-crates.tar.xz` under the mndz-overlay-assets release for `hk-1.50.0`
- **AND** the primary source line is the upstream GitHub source archive

#### Scenario: CratesIo source distfile form

- **WHEN** the manager rewrites SRC_URI for `dev-util/biodiff` at any PV
- **THEN** the primary source line is `https://crates.io/api/v1/crates/biodiff/${PV}/download -> biodiff-${PV}.crate`
- **AND** the secondary line references `biodiff-${PV}-crates.tar.xz` under the mndz-overlay-assets release for `biodiff-${PV}`

#### Scenario: Empty CRATES keeps GIT_CRATES and V8 extras

- **WHEN** the manager rewrites SRC_URI for `dev-util/codex` whose ebuild has empty `CRATES`, a `GIT_CRATES` map, `${CARGO_CRATE_URIS}`, a rusty_v8 snapshot line, and Chromium GCS clang/rust-toolchain lines
- **THEN** `GIT_CRATES` URIs and the extra V8/clang/rust-toolchain lines remain
- **AND** SRC_URI is not reduced to only the GitHub archive plus `{pn}-${PV}-crates.tar.xz`

### Requirement: Cargo reuse path skips pycargoebuild

When a planned Cargo PV needs work, has a derivable reuse-write floor, is not forced full, and an assets release provides every required asset basename including `{pn}-{pv}-crates.tar.xz` and any rusty_v8 submodule sidecar required for that lock’s `v8` pin, the program SHALL reuse those assets when downloaded bytes pass expected Manifest/trusted-hash verification. Reuse SHALL NOT run pycargoebuild, manager crate packing, rusty_v8 clone, or release publication. It MAY rewrite KEYWORDS, `RUST_MIN_VER`, and SRC_URI for plan adequacy, SHALL ensure steady-state tarball shape has empty `CRATES`, then SHALL run `ebuild ... manifest` and verify as for other `DepsAndAssets` ecosystems.

If the crates release tag exists but any required asset is missing, or if the PV is forced full because no reuse-write floor is derivable, the package SHALL hard-fail before mutation because full publication cannot update, replace, or delete an existing release tag. Absence of the crates release tag SHALL permit the full path. A missing rusty_v8 snapshot for a new `v8` pin SHALL NOT by itself force the crates full path when the crates tag is absent; full-path SHALL harvest the snapshot as specified by the rusty_v8 submodule sidecar requirement.

#### Scenario: Clean reuse no pycargoebuild

- **WHEN** all required release assets for `usage-3.5.4` exist, their bytes verify, and its reuse-write floor is derivable
- **THEN** apply does not invoke pycargoebuild for that unit

#### Scenario: Clean reuse no manager crate pack

- **WHEN** all required release assets for `usage-3.5.4` exist, their bytes verify, and its reuse-write floor is derivable
- **THEN** apply does not run manager crate packing for that unit

#### Scenario: Reuse clears list-era CRATES

- **WHEN** reuse applies for a PV whose canonical template still has a non-empty `CRATES` list
- **THEN** the written ebuild has empty `CRATES` suitable for crate-tarball packaging

#### Scenario: Existing release cannot satisfy forced-full Cargo unit

- **WHEN** all required assets exist but the Cargo PV is forced full because it has no derivable reuse-write floor
- **THEN** the package hard-fails with release-tag guidance and does not run pycargoebuild or mutate local/remote assets

#### Scenario: Existing tag missing asset hard-fails

- **WHEN** the crates release tag for a planned Cargo PV exists but `{pn}-{pv}-crates.tar.xz` is missing from that release
- **THEN** the package hard-fails before overlay mutation

### Requirement: Hardcoded cargo packages enabled

The hardcoded policy map SHALL set `DepsAndAssets` with ecosystem `Cargo` for `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` with their existing GitHub sources (`jdx` / respective repos / tag prefix `v`) and provenance `CargoGitTag`, for `dev-util/biodiff` with GitHub source `8051enthusiast`/`biodiff` (tag prefix `v`) and provenance `CargoCratesIo`, and for `dev-util/codex` with GitHub source `openai`/`codex` (tag prefix `rust-v`), lock subdirectory `codex-rs`, package subdirectory `codex-rs/cli`, and provenance `CargoGitTag`. Those packages SHALL NOT remain `Unsupported` solely for cargo CRATES regeneration. Policy for `usage` SHALL use package subdirectory `cli` when required for package metadata. Policy for `codex` SHALL restrict runtime-lane arches to amd64 as specified by `runtime-lanes`.

#### Scenario: mise technique

- **WHEN** policy is resolved for `dev-util/mise`
- **THEN** the technique is `DepsAndAssets Cargo` with provenance `CargoGitTag` and the source is GitHub `jdx/mise` with tag prefix `v`

#### Scenario: usage not Unsupported

- **WHEN** policy is resolved for `dev-util/usage`
- **THEN** the technique is not `Unsupported`

#### Scenario: biodiff technique

- **WHEN** policy is resolved for `dev-util/biodiff`
- **THEN** the technique is `DepsAndAssets Cargo` with provenance `CargoCratesIo` and the source is GitHub `8051enthusiast`/`biodiff` with tag prefix `v`

#### Scenario: codex technique

- **WHEN** policy is resolved for `dev-util/codex`
- **THEN** the technique is `DepsAndAssets Cargo` with provenance `CargoGitTag`, lock subdirectory `codex-rs`, package subdirectory `codex-rs/cli`, and the source is GitHub `openai/codex` with tag prefix `rust-v`
