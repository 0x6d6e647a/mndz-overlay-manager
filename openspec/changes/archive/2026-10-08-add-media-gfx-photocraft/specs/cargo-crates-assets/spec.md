# cargo-crates-assets Delta

## MODIFIED Requirements

### Requirement: Hardcoded cargo packages enabled

The hardcoded policy map SHALL set `DepsAndAssets` with ecosystem `Cargo` for `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` with their existing GitHub sources (`jdx` / respective repos / tag prefix `v`) and provenance `CargoGitTag`, for `dev-util/biodiff` with GitHub source `8051enthusiast`/`biodiff` (tag prefix `v`) and provenance `CargoCratesIo`, and for `dev-util/codex` with GitHub source `openai`/`codex` (tag prefix `rust-v`), lock subdirectory `codex-rs`, package subdirectory `codex-rs/cli`, and provenance `CargoGitTag`. Those packages SHALL NOT remain `Unsupported` solely for cargo CRATES regeneration. Policy for `usage` SHALL use package subdirectory `cli` when required for package metadata. Policy for `codex` SHALL restrict runtime-lane arches to amd64 as specified by `runtime-lanes`. Policy for `media-gfx/photocraft` SHALL use GitHub source `storytold`/`photocraft` (tag prefix `v`), provenance `CargoGitTag`, no lock subdirectory, package subdirectory `apps/photocraft`, and SHALL restrict runtime-lane arches to `amd64`, `x86`, `arm`, `arm64`, `ppc64`, `loong`, `riscv`, `sparc`, and `s390`.

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

#### Scenario: photocraft technique

- **WHEN** policy is resolved for `media-gfx/photocraft`
- **THEN** the technique is `DepsAndAssets Cargo` with provenance `CargoGitTag`, no lock subdirectory, and package subdirectory `apps/photocraft`
- **AND** the source is GitHub `storytold/photocraft` with tag prefix `v`
- **AND** the runtime-lane allowlist is `amd64`, `x86`, `arm`, `arm64`, `ppc64`, `loong`, `riscv`, `sparc`, and `s390`

## ADDED Requirements

### Requirement: Photocraft donor body survives Cargo rewrite

A Cargo full-path or reuse rewrite of `media-gfx/photocraft` SHALL preserve `IUSE`, `REQUIRED_USE`, conditional dependencies, `src_compile`, `src_install`, `src_test`, the desktop integration install, and every `LICENSE` term outside the generated crate-license block. The rewrite SHALL still update the PV filename, KEYWORDS, `RUST_MIN_VER`, `CRATES`, the generated crate-license block, and the assets `SRC_URI` as specified for Cargo.

#### Scenario: USE contract survives a newer PV

- **WHEN** apply rewrites the `0.1.1` donor into a newer numeric PV
- **THEN** the new ebuild still declares `IUSE="+gui +cli +portal +X +wayland test"` and the seed `REQUIRED_USE`
- **AND** `src_test` still runs workspace tests excluding `photocraft-web` and `xtask`
- **AND** `SCOWL` remains in `LICENSE`

#### Scenario: Generated crate block may change

- **WHEN** the newer tag's lock changes the generated crate-license block
- **THEN** that generated block is updated
- **AND** the `SCOWL`, `OFL-1.1`, `ISC`, and `CC0-1.0` terms outside that block remain
