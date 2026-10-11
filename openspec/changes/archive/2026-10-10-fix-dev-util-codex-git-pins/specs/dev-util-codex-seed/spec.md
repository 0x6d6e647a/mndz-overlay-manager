# Spec Delta

## ADDED Requirements

### Requirement: Patch-table commits follow GIT_CRATES

The codex ebuild template SHALL rewrite workspace `[patch.crates-io]` git lines for `crossterm`, `tokio-tungstenite`, and `tungstenite` to the unpacked path from each crate's `GIT_CRATES` entry. The commit SHALL be that entry's commit. `src_prepare` SHALL die when one of those crates is missing from `GIT_CRATES`, the workspace manifest has no git line for that commit, or the unpacked checkout is absent.

#### Scenario: Crossterm follows the GIT_CRATES commit

- **WHEN** `GIT_CRATES` records `crossterm` at commit `ed1cdab335221515706178d68495bba2aed1924f` and the workspace manifest pins that same commit
- **THEN** `src_prepare` rewrites that line to the unpacked `crossterm-ed1cdab335221515706178d68495bba2aed1924f` path
- **AND** `src_prepare` does not require commit `45fecb9508105988f42fe6ff0441783ed3717f92`

#### Scenario: Repeated tungstenite lines

- **WHEN** the workspace manifest contains more than one `tungstenite` git line for the `GIT_CRATES` commit
- **THEN** `src_prepare` rewrites every such line to that entry's unpacked path

#### Scenario: Missing pin dies

- **WHEN** `GIT_CRATES` lists one of those three crates at a commit and the workspace manifest has no git line for that crate at that commit
- **THEN** `src_prepare` dies
- **AND** the build does not continue into `src_compile`

### Requirement: Windows workspace git deps stay stubbed

`src_prepare` SHALL point the workspace git dependencies `appcontainer_common` and `learning_mode_windows` at empty local package stubs. Those two crate names SHALL NOT be `GIT_CRATES` keys. An offline resolve of Linux `codex` and `codex-code-mode-host` SHALL load those two names from the stubs.

#### Scenario: learning_mode_windows is a stub

- **WHEN** `src_prepare` finishes for a tree whose workspace manifest pins `learning_mode_windows` at the microsoft/mxc git remote
- **THEN** that dependency's source is the local stub
- **AND** the resolve does not check out that remote for `learning_mode_windows`

#### Scenario: Stub names stay out of GIT_CRATES

- **WHEN** the ebuild's `GIT_CRATES` array is inspected
- **THEN** it has no `appcontainer_common` key and no `learning_mode_windows` key
