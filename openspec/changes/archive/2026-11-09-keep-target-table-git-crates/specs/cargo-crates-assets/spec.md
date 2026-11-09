# Spec Delta

## MODIFIED Requirements

### Requirement: Windows-only git remotes omitted from GIT_CRATES

When writing or repairing `GIT_CRATES` for a Cargo GitTag ebuild other than `dev-util/codex`, the program SHALL keep a lock git package that any manifest edge names, including an edge that sits only under a windows-only or wasm-only target table. Dev-dependencies are not edges. For `dev-util/codex`, the program SHALL omit a lock git package when every such edge is windows-only or wasm-only. That omit includes `microsoft/mxc` and `appcontainer_common`.

#### Scenario: mxc dumped

- **WHEN** the manager writes `GIT_CRATES` for `dev-util/codex`
- **THEN** the map has no `microsoft/mxc` entry
- **AND** Linux git remotes such as `crossterm` remain

#### Scenario: A Linux edge keeps a crate also named on Windows or wasm

- **WHEN** a Cargo GitTag rewrite sees a lock git package named by a dependency that is outside windows-only and wasm-only target tables
- **AND** a Windows or `wasm32` target table also names that package
- **THEN** `GIT_CRATES` includes that package

#### Scenario: A wasm-only git package is omitted

- **WHEN** a Cargo GitTag rewrite for `dev-util/codex` sees a lock git package named only from a `wasm32` target table
- **THEN** `GIT_CRATES` omits that package

#### Scenario: A wasm-only git package stays

- **WHEN** a Cargo GitTag rewrite for a package other than `dev-util/codex` sees a lock git package named only from a `wasm32` target table
- **THEN** `GIT_CRATES` includes that package
