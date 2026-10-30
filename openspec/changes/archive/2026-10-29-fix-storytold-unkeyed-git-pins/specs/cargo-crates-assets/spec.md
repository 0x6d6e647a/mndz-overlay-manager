# Spec Delta

## MODIFIED Requirements

### Requirement: Windows-only git remotes omitted from GIT_CRATES

When writing or repairing `GIT_CRATES` for a Cargo GitTag ebuild, the program SHALL omit a lock git package only when every dependency edge for that package in the active Linux set's manifests is windows-only or wasm-only. A package that any non-windows, non-wasm dependency of that set names SHALL remain. `microsoft/mxc` / `appcontainer_common` for Codex SHALL be omitted.

#### Scenario: mxc dumped

- **WHEN** the manager writes `GIT_CRATES` for `dev-util/codex`
- **THEN** the map has no `microsoft/mxc` entry
- **AND** Linux git remotes such as `crossterm` remain

#### Scenario: A Linux edge keeps a crate also named on Windows or wasm

- **WHEN** a Cargo GitTag rewrite sees a lock git package named by a dependency that is outside windows-only and wasm-only target tables
- **AND** a Windows or `wasm32` target table also names that package
- **THEN** `GIT_CRATES` includes that package

#### Scenario: A wasm-only git package is omitted

- **WHEN** a lock git package is named only from a `wasm32` target table of the active Linux set
- **THEN** `GIT_CRATES` omits that package
