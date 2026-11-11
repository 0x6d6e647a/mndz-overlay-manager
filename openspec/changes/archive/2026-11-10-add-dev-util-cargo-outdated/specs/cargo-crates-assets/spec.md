# Spec Delta

## ADDED Requirements

### Requirement: cargo-outdated policy

The hardcoded policy map SHALL set `dev-util/cargo-outdated` to `DepsAndAssets` Cargo with provenance `CargoCratesIo`, GitHub source `kbknapp`/`cargo-outdated`, tag prefix `v`, no lock subdirectory, and no package subdirectory. The runtime-lane arch allowlist SHALL be empty, admitting every discovered runtime arch.

#### Scenario: Policy lookup

- **WHEN** policy is resolved for `dev-util/cargo-outdated`
- **THEN** the technique is `DepsAndAssets` Cargo with provenance `CargoCratesIo`
- **AND** the source is GitHub `kbknapp`/`cargo-outdated` with tag prefix `v`
- **AND** there is no lock subdirectory and no package subdirectory
- **AND** the runtime-lane arch allowlist is empty

### Requirement: cargo-outdated donor body survives Cargo rewrite

A Cargo rewrite of `dev-util/cargo-outdated` SHALL preserve `IUSE`, `REQUIRED_USE`, `RESTRICT`, conditional dependencies, the system-versus-bundled build selection, the program install, `src_test`, and `QA_FLAGS_IGNORED`. The rewrite SHALL still update the PV filename, `KEYWORDS`, `RUST_MIN_VER`, `CRATES`, the generated crate-license block, and the assets `SRC_URI`.

#### Scenario: Bump keeps the USE contract

- **WHEN** apply rewrites the `0.18.0` donor into PV `0.19.0`
- **THEN** the new ebuild still declares `+system-openssl`, `+system-libcurl`, `+system-libgit2`, `+system-libssh2`, `+system-zlib`, `+system-sqlite`, `+libsecret`, and `test`
- **AND** `REQUIRED_USE` still holds all four fence rules, across its original lines
- **AND** `QA_FLAGS_IGNORED` still names `/usr/bin/cargo-outdated`
- **AND** the primary source line remains the crates.io download for `${PV}`
