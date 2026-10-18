# cargo-crates-assets Delta

## ADDED Requirements

### Requirement: Storytold patch-pin rewrite hook

When a Cargo rewrite writes a Storytold craft ebuild that declares `GIT_CRATES`, the ebuild SHALL inherit `mndz-cargo` after `cargo` and its `src_prepare` SHALL call `mndz-cargo_rewrite_patch_git_pins` after `default`. A Storytold craft ebuild with no `GIT_CRATES` declaration SHALL NOT gain that inherit or that call. A non-Storytold Cargo ebuild, including `dev-util/codex`, SHALL NOT gain them.

#### Scenario: Missing phase gains the hook

- **WHEN** a Cargo rewrite receives a Storytold craft ebuild that declares `GIT_CRATES`, inherits `cargo` before `desktop`, and defines no `src_prepare`
- **THEN** the result inherits `mndz-cargo` after `cargo`
- **AND** the result defines `src_prepare` that calls `default` and then `mndz-cargo_rewrite_patch_git_pins`

#### Scenario: Existing hook stays put

- **WHEN** a Cargo rewrite receives a Storytold craft ebuild that already inherits `mndz-cargo` after `cargo` and whose `src_prepare` already calls `mndz-cargo_rewrite_patch_git_pins` after `default`
- **THEN** the inherit line and that `src_prepare` stay as they were

#### Scenario: No GIT_CRATES omits the hook

- **WHEN** a Cargo rewrite receives a Storytold craft ebuild with empty `CRATES`, no `GIT_CRATES` declaration, and no `src_prepare`
- **THEN** the result does not inherit `mndz-cargo`
- **AND** the result does not call `mndz-cargo_rewrite_patch_git_pins`

#### Scenario: Codex stays on its own rewrite

- **WHEN** a Cargo rewrite writes `dev-util/codex`
- **THEN** the ebuild does not inherit `mndz-cargo`
- **AND** the ebuild does not call `mndz-cargo_rewrite_patch_git_pins`

### Requirement: Storytold patch-pin hook keeps an existing prepare

When a Cargo rewrite inserts the patch-pin hook into an existing `src_prepare`, every other statement in that phase SHALL remain. When that phase has no `default` call, the rewrite SHALL hard-fail the package before ebuild, Manifest, or commit mutation.

#### Scenario: Donor prepare body survives

- **WHEN** a Storytold craft ebuild declares `GIT_CRATES` and its `src_prepare` calls `default` and then edits a source file
- **THEN** the result still edits that source file
- **AND** `mndz-cargo_rewrite_patch_git_pins` is called after `default` and before that edit

#### Scenario: Missing default hard-fails

- **WHEN** a Storytold craft ebuild declares `GIT_CRATES` and its `src_prepare` does not call `default`
- **THEN** the package hard-fails before ebuild, Manifest, or commit mutation
- **AND** the ebuild file is left unchanged
