# Spec Delta

## ADDED Requirements

### Requirement: Cargo target_env classification

The Cargo tag-floor walk and the source-tree harvest SHALL evaluate `cfg` atoms named `target_env`. The value `gnu` SHALL hold for the Linux family only. The value `msvc` SHALL hold for the Windows family only. The value `musl` and every other value SHALL NOT hold for Linux, macOS, BSD, Windows, or wasm. A target table that matches no modeled family SHALL be ignored and SHALL NOT make the candidate incomplete because of that `target_env` atom.

#### Scenario: Musl-only path crate does not raise the floor

- **WHEN** the policy package declares `rust-version = "1.91"` and a path crate declaring `1.99` is reachable only through `cfg(all(target_os = "linux", target_env = "musl"))`
- **THEN** the candidate is complete
- **AND** the planned tag floor and source harvest are `1.91.0`

#### Scenario: Gnu path crate is active on Linux

- **WHEN** the policy package declares `rust-version = "1.91"` and a path crate declaring `1.92` is reachable only through `cfg(all(target_os = "linux", target_env = "gnu"))`
- **THEN** the planned tag floor is `1.92.0`

#### Scenario: Msvc-only path crate is ignored

- **WHEN** a path crate declaring `1.99` is reachable only through `cfg(all(target_os = "windows", target_env = "msvc"))`
- **THEN** that crate does not raise the planned tag floor and does not make the candidate incomplete

#### Scenario: Unknown target_env value does not make the candidate incomplete

- **WHEN** a path crate declaring `1.99` is reachable only through `cfg(target_env = "sgx")`
- **THEN** the candidate is complete and that crate does not raise the planned tag floor

### Requirement: Cargo CPU target_arch classification

The Cargo tag-floor walk and the source-tree harvest SHALL evaluate `cfg` atoms named `target_arch`. `wasm32` and `wasm64` SHALL hold for the wasm family only. The values `x86_64`, `x86`, `aarch64`, `arm`, `loongarch64`, `mips`, `mips64`, `powerpc`, `powerpc64`, `riscv32`, `riscv64`, `s390x`, `sparc`, and `sparc64` SHALL hold for every non-wasm family and SHALL NOT hold for wasm. Any other `target_arch` value SHALL make the candidate incomplete.

#### Scenario: Codex musl allocator table is ignored

- **WHEN** a path crate declaring `1.99` is reachable only through `cfg(all(target_os = "linux", target_env = "musl", any(target_arch = "x86_64", target_arch = "aarch64")))` and the rest of the active set declares `1.91`
- **THEN** the candidate is complete and the planned tag floor is `1.91.0`

#### Scenario: CPU-arch path crate is active

- **WHEN** the policy package declares `rust-version = "1.91"` and a path crate declaring `1.93` is reachable only through `cfg(target_arch = "x86_64")`
- **THEN** the planned tag floor is `1.93.0`

#### Scenario: Wasm-only path crate stays ignored

- **WHEN** a path crate declaring `1.99` is reachable only through `cfg(target_arch = "wasm32")`
- **THEN** that crate does not raise the planned tag floor and does not make the candidate incomplete

#### Scenario: Unlisted target_arch stays incomplete

- **WHEN** a target table uses `cfg(target_arch = "nvptx64")`
- **THEN** the candidate is incomplete and is not selected as requirement `0.0.0`
