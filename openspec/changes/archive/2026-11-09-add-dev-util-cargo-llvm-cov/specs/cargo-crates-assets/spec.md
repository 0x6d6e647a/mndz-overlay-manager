## ADDED Requirements

### Requirement: Lockless Git tag materialize

For provenance `CargoGitTagGenerateLock`, full-path materialize SHALL follow the `CargoGitTag` clone, `pycargoebuild`, and pack steps inside the materialize container. Before `pycargoebuild`, an absent `Cargo.lock` at the lock root SHALL be created there with `cargo generate-lockfile`. An existing `Cargo.lock` SHALL be left unchanged. A non-zero `cargo generate-lockfile` SHALL hard-fail the unit and name the lock root.

#### Scenario: Missing lock is generated

- **WHEN** full-path materialize runs for provenance `CargoGitTagGenerateLock` and the tag checkout has no `Cargo.lock` at the lock root
- **THEN** the materialize container runs `cargo generate-lockfile` in that lock root before `pycargoebuild`
- **AND** the pack uses the generated `Cargo.lock`

#### Scenario: Existing lock is kept

- **WHEN** full-path materialize runs for provenance `CargoGitTagGenerateLock` and `Cargo.lock` is already at the lock root
- **THEN** the program does not run `cargo generate-lockfile`
- **AND** `pycargoebuild` and the pack use that existing lock

#### Scenario: Generate failure hard-fails

- **WHEN** `cargo generate-lockfile` exits non-zero for a `CargoGitTagGenerateLock` unit
- **THEN** the unit hard-fails and the error names the lock root
- **AND** `pycargoebuild` does not run

### Requirement: Git tag provenance still requires a lock

Provenance `CargoGitTag` SHALL hard-fail full-path materialize when `Cargo.lock` is absent at the lock root. That provenance SHALL NOT run `cargo generate-lockfile`.

#### Scenario: Missing lock is not generated

- **WHEN** full-path materialize runs for provenance `CargoGitTag` and `Cargo.lock` is absent at the lock root
- **THEN** the unit hard-fails
- **AND** the program does not run `cargo generate-lockfile`

### Requirement: cargo-llvm-cov policy

The hardcoded policy map SHALL set `dev-util/cargo-llvm-cov` to `DepsAndAssets` Cargo with provenance `CargoGitTagGenerateLock`, GitHub source `taiki-e`/`cargo-llvm-cov`, tag prefix `v`, no lock subdirectory, and no package subdirectory. The runtime-lane arch allowlist SHALL be empty, admitting every discovered runtime arch.

#### Scenario: Policy lookup

- **WHEN** policy is resolved for `dev-util/cargo-llvm-cov`
- **THEN** the technique is `DepsAndAssets` Cargo with provenance `CargoGitTagGenerateLock`
- **AND** the source is GitHub `taiki-e`/`cargo-llvm-cov` with tag prefix `v`
- **AND** there is no lock subdirectory and no package subdirectory
- **AND** the runtime-lane arch allowlist is empty

### Requirement: cargo-llvm-cov donor body survives Cargo rewrite

A Cargo rewrite of `dev-util/cargo-llvm-cov` SHALL preserve `IUSE`, `RESTRICT`, `RDEPEND`, `BDEPEND`, the `/usr/bin/cargo-llvm-cov` wrapper install, `src_prepare`'s `test-helper` path rewrite, `src_test` including the `trybuild` and `ui_test` skips, and `QA_FLAGS_IGNORED`. The rewrite SHALL still update the PV filename, `KEYWORDS`, `RUST_MIN_VER`, `CRATES`, `GIT_CRATES`, the generated crate-license block, and the assets `SRC_URI`.

#### Scenario: Bump keeps the wrapper and the test phase

- **WHEN** apply rewrites the `0.9.0` donor into PV `0.9.1`
- **THEN** the new ebuild still installs the wrapper at `/usr/bin/cargo-llvm-cov` and the binary at `/usr/libexec/cargo-llvm-cov/cargo-llvm-cov`
- **AND** `src_test` still skips `trybuild` and `ui_test`
- **AND** `src_prepare` still rewrites the `test-helper` git pin to a local path
- **AND** `RDEPEND` still includes unslotted `llvm-core/llvm`

## MODIFIED Requirements

### Requirement: Cargo ecosystem under DepsAndAssets

The library SHALL support `DepsAndAssets` with ecosystem `Cargo`. Policy SHALL declare a Cargo provenance: `CargoGitTag`, `CargoGitTagGenerateLock`, or `CargoCratesIo`. Policy MAY supply an optional lock subdirectory (relative to the repository root; `Nothing` means root) where `Cargo.lock` is expected, and an optional package subdirectory for the binary package (`Nothing` means same as lock root). The package subdirectory, when set, is the policy package: tag-floor discovery SHALL start there, and full-path materialize SHALL run `pycargoebuild` with that directory as its argument (workspace members such as usage’s `cli/`). When unset, tag-floor discovery and `pycargoebuild` SHALL start at the lock root. Provenance `CargoGitTag` and `CargoCratesIo` SHALL require an existing `Cargo.lock` at the lock root. Provenance `CargoGitTagGenerateLock` SHALL use that lock when it exists and SHALL create it when it is absent, as specified by lockless Git tag materialize. Cargo resolves the lockfile by walking parents. Apply SHALL require a `GitHub` update source for provenance `CargoGitTag` and `CargoGitTagGenerateLock` and SHALL hard-fail if the source is not GitHub; provenance `CargoCratesIo` packages MAY use a `GitHub` update source for version detection and tag-floor probing while materialization uses the published crates.io crate. A virtual workspace root (`[workspace]` without `[package]`) with no package subdirectory SHALL fail planning with an error that names the missing package subdirectory.

#### Scenario: usage package subdir

- **WHEN** policy for `dev-util/usage` uses `DepsAndAssets Cargo` with package subdirectory `cli` and lock at repository root
- **THEN** tag-floor discovery starts at `cli/Cargo.toml` and includes that package’s local path closure
- **AND** `pycargoebuild` runs with the `cli` directory as its directory argument (not the workspace root)

#### Scenario: hk root cargo

- **WHEN** policy for `dev-util/hk` uses `DepsAndAssets Cargo` with no subdirectories
- **THEN** both lock and package metadata are taken from the repository root and `pycargoebuild` runs at the repository root

#### Scenario: Virtual workspace without package subdirectory fails

- **WHEN** a Cargo package’s tagged root has `[workspace]` and no `[package]`, and policy sets no package subdirectory
- **THEN** planning hard-fails without treating the candidate as absent-floor `0.0.0`

#### Scenario: biodiff crates.io provenance

- **WHEN** policy for `dev-util/biodiff` uses `DepsAndAssets Cargo` with provenance `CargoCratesIo` and source GitHub `8051enthusiast`/`biodiff` with tag prefix `v`
- **THEN** version detection and tag-floor probing use that GitHub source
- **AND** full-path materialize uses the published crates.io crate for the target PV, not the git tag

#### Scenario: cargo-llvm-cov generates a missing lock

- **WHEN** policy for `dev-util/cargo-llvm-cov` uses provenance `CargoGitTagGenerateLock` and the tag has no `Cargo.lock`
- **THEN** version detection uses GitHub `taiki-e`/`cargo-llvm-cov` with tag prefix `v`
- **AND** full-path materialize creates `Cargo.lock` before `pycargoebuild`

### Requirement: Manager-owned SRC_URI for cargo

After pycargoebuild inplace update on full path (or on content repair), the program SHALL rewrite the ebuild `SRC_URI` to the provenance-appropriate primary source line plus the assets-repository crates tarball URL for `{pn}-${PV}-crates.tar.xz` (`https://github.com/{owner}/{repo}/releases/download/` using `{owner}/{repo}` from `assets-path` `origin`), and SHALL NOT rely on `${CARGO_CRATE_URIS}` as the **registry** dependency distfile source for steady-state tarball-shaped ebuilds. Provenance `CargoGitTag` and `CargoGitTagGenerateLock`: the primary source line is the upstream GitHub source archive for the tag. Provenance `CargoCratesIo`: the primary source line is the canonical crates.io download distfile for the policy crate name and PV, `https://crates.io/api/v1/crates/<crate>/<pv>/download -> <p>.crate`.

The program SHALL treat `${CARGO_CRATE_URIS}` as list-era registry URIs **only when `CRATES` is non-empty**. When `CRATES` is empty, the rewrite SHALL preserve `GIT_CRATES` URI expansion (`${CARGO_CRATE_URIS}` as used for git crates) and SHALL preserve extra `SRC_URI` lines that are neither the GitHub/crates.io primary source nor the crates tarball (including rusty_v8 snapshot and Chromium GCS clang/rust-toolchain distfiles). The program SHALL NOT collapse those ebuilds to a two-line github-archive-plus-crates form.

#### Scenario: Assets crates URL present

- **WHEN** the manager rewrites SRC_URI for `dev-util/hk` at PV `1.50.0`
- **THEN** SRC_URI references `hk-1.50.0-crates.tar.xz` under the origin assets-repo release for `hk-1.50.0`
- **AND** the primary source line is the upstream GitHub source archive

#### Scenario: CratesIo source distfile form

- **WHEN** the manager rewrites SRC_URI for `dev-util/biodiff` at any PV
- **THEN** the primary source line is `https://crates.io/api/v1/crates/biodiff/${PV}/download -> biodiff-${PV}.crate`
- **AND** the secondary line references `biodiff-${PV}-crates.tar.xz` under the origin assets-repo release for `biodiff-${PV}`

#### Scenario: Empty CRATES keeps GIT_CRATES and V8 extras

- **WHEN** the manager rewrites SRC_URI for `dev-util/codex` whose ebuild has empty `CRATES`, a `GIT_CRATES` map, `${CARGO_CRATE_URIS}`, a rusty_v8 snapshot line, and Chromium GCS clang/rust-toolchain lines
- **THEN** `GIT_CRATES` URIs and the extra V8/clang/rust-toolchain lines remain
- **AND** SRC_URI is not reduced to only the GitHub archive plus `{pn}-${PV}-crates.tar.xz`

#### Scenario: Crates URL uses origin owner and repo

- **WHEN** `assets-path` `origin` is `https://github.com/alice/overlay-assets.git` and the program writes a crates assets `SRC_URI`
- **THEN** the URL host path is `github.com/alice/overlay-assets/releases/download/`

#### Scenario: Lockless Git tag keeps the GitHub archive

- **WHEN** the manager rewrites SRC_URI for `dev-util/cargo-llvm-cov` at PV `0.9.1`
- **THEN** the primary source line is the upstream GitHub tag archive
- **AND** the assets line references `cargo-llvm-cov-0.9.1-crates.tar.xz`
- **AND** a `GIT_CRATES` fetch line using `${CARGO_CRATE_URIS}` remains when `CRATES` is empty and `GIT_CRATES` is declared

### Requirement: Cargo provenance coherence

Apply-time content checks SHALL enforce provenance coherence for `DepsAndAssets` Cargo packages: the policy provenance, the ebuild primary source line form, and the materialize/pack provenance SHALL agree. Provenance `CargoGitTag` and `CargoGitTagGenerateLock` require a primary `github.com/…/archive/` source line; provenance `CargoCratesIo` requires the canonical crates.io download source line. A mismatch SHALL hard-fail the package before ebuild, Manifest, asset-publication, or commit mutation, naming the policy provenance and the observed source form.

#### Scenario: Coherent CratesIo ebuild admitted

- **WHEN** apply assesses a biodiff ebuild whose primary source line is the crates.io download distfile and policy provenance is `CargoCratesIo`
- **THEN** the coherence check passes and apply proceeds

#### Scenario: Coherence mismatch hard-fails before commit

- **WHEN** a biodiff ebuild carries a GitHub archive source line while policy provenance is `CargoCratesIo` (or the reverse mismatch)
- **THEN** apply hard-fails the package naming the expected and observed source form, before Manifest, assets publication, or commit

#### Scenario: Lockless Git tag admits a GitHub archive

- **WHEN** apply assesses a `dev-util/cargo-llvm-cov` ebuild whose primary source line is a `github.com/…/archive/` line and policy provenance is `CargoGitTagGenerateLock`
- **THEN** the coherence check passes and apply proceeds

#### Scenario: Lockless Git tag rejects a crates.io primary source

- **WHEN** a `dev-util/cargo-llvm-cov` ebuild's primary source line is the crates.io download distfile while policy provenance is `CargoGitTagGenerateLock`
- **THEN** apply hard-fails the package naming the expected and observed source form, before Manifest, assets publication, or commit
