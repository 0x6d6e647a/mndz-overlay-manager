# Spec Delta

## ADDED Requirements

### Requirement: cargo-update policy

The hardcoded policy map SHALL set `dev-util/cargo-update` to `DepsAndAssets` Cargo with provenance `CargoCratesIo`, GitHub source `nabijaczleweli`/`cargo-update`, tag prefix `v`, no lock subdirectory, and no package subdirectory. The runtime-lane arch allowlist SHALL be empty, admitting every discovered runtime arch.

#### Scenario: Policy lookup

- **WHEN** policy is resolved for `dev-util/cargo-update`
- **THEN** the technique is `DepsAndAssets` Cargo with provenance `CargoCratesIo`
- **AND** the source is GitHub `nabijaczleweli`/`cargo-update` with tag prefix `v`
- **AND** there is no lock subdirectory and no package subdirectory
- **AND** the runtime-lane arch allowlist is empty

### Requirement: cargo-update donor body survives Cargo rewrite

A Cargo rewrite of `dev-util/cargo-update` SHALL preserve `IUSE`, `REQUIRED_USE`, `RESTRICT`, conditional dependencies, the system-versus-vendored build selection, the install of both programs and the optional man pages, `src_test`, and `QA_FLAGS_IGNORED`. The rewrite SHALL still update the PV filename, `KEYWORDS`, `RUST_MIN_VER`, `CRATES`, the generated crate-license block, and the assets `SRC_URI`.

#### Scenario: Bump keeps the USE contract

- **WHEN** apply rewrites the `22.1.0` donor into PV `22.1.1`
- **THEN** the new ebuild still declares `+system-openssl`, `+system-libgit2`, `+system-libcurl`, `+libsecret`, `+man`, and `test`
- **AND** `REQUIRED_USE` is still `system-libcurl? ( system-openssl )`
- **AND** the install still provides `/usr/bin/cargo-install-update` and `/usr/bin/cargo-install-update-config`
- **AND** the primary source line remains the crates.io download for `${PV}`

## MODIFIED Requirements

### Requirement: Cargo win7 target_vendor classification

The Cargo tag-floor walk and the source-tree harvest SHALL evaluate `cfg` atoms named `target_vendor` whose value is `win7` or `apple`. Neither value SHALL hold for Linux, macOS, BSD, Windows, or wasm. A target table that matches no modeled family because of that atom SHALL be ignored and SHALL NOT make the candidate incomplete. Any other `target_vendor` value, including `unknown`, SHALL make the candidate incomplete.

#### Scenario: Windows table that excludes win7 is ignored

- **WHEN** the policy package declares `rust-version = "1.91"` and a path crate declaring `1.99` is reachable only through `cfg(all(windows, not(target_vendor = "win7")))`
- **THEN** the candidate is complete
- **AND** the planned tag floor is `1.91.0`

#### Scenario: A table for every non-win7 target stays active

- **WHEN** the policy package declares `rust-version = "1.91"` and a path crate declaring `1.94` is reachable only through `cfg(not(target_vendor = "win7"))`
- **THEN** the planned tag floor is `1.94.0`

#### Scenario: Apple-only table is ignored

- **WHEN** the policy package declares `rust-version = "1.86"` and a path crate declaring `1.99` is reachable only through `cfg(target_vendor = "apple")`
- **THEN** the candidate is complete
- **AND** the planned tag floor is `1.86.0`

#### Scenario: Unix table that excludes apple stays active

- **WHEN** the policy package declares `rust-version = "1.86"` and a path crate declaring `1.94` is reachable only through `cfg(all(unix, not(target_vendor = "apple")))`
- **THEN** the planned tag floor is `1.94.0`

#### Scenario: Other target_vendor values stay incomplete

- **WHEN** a target table uses `cfg(target_vendor = "unknown")`
- **THEN** the candidate is incomplete and is not selected as requirement `0.0.0`
