# storytold-craft-apps Delta

## ADDED Requirements

### Requirement: DesignCraft rewrites patch-table git pins

DesignCraft `src_prepare` SHALL rewrite every one-line `[patch.*]` git pin whose crate name and `rev` equal a `GIT_CRATES` entry to the Portage work directory plus that entry's directory, with `%commit%` replaced by that entry's commit.

#### Scenario: Hayro follows the pdfcraft checkout

- **WHEN** `GIT_CRATES` records `hayro` at commit `b5467d93a0ffaa5e5e6658bccdf8655a3ba689c9` with directory `pdfcraft-%commit%/vendor/hayro` and `[patch.crates-io]` pins `hayro` at that rev
- **THEN** `src_prepare` rewrites that line to the unpacked `pdfcraft-b5467d93a0ffaa5e5e6658bccdf8655a3ba689c9/vendor/hayro` path
- **AND** the `src_prepare` source does not contain that commit as a literal

#### Scenario: Winit follows its checkout

- **WHEN** `GIT_CRATES` records `winit` at commit `3d51077fd1a966f84df9ef287839dc84fd5b4ca7` and `[patch.crates-io]` pins `winit` at that rev on a URL that ends in `.git`
- **THEN** `src_prepare` rewrites that line to the unpacked `winit-3d51077fd1a966f84df9ef287839dc84fd5b4ca7` path

#### Scenario: Repeated patch lines

- **WHEN** more than one `[patch.*]` line names the same crate at the `GIT_CRATES` commit
- **THEN** `src_prepare` rewrites every such line to that entry's unpacked path

### Requirement: DesignCraft rejects an unresolvable patch pin

DesignCraft `src_prepare` SHALL die before `src_compile` when a one-line `[patch.*]` git pin has no `GIT_CRATES` entry for that crate name and `rev`, or the rewritten checkout has no `Cargo.toml`.

#### Scenario: Missing GIT_CRATES entry

- **WHEN** a one-line `[patch.*]` git pin names a crate and rev that `GIT_CRATES` does not record
- **THEN** `src_prepare` dies
- **AND** the build does not continue into `src_compile`

#### Scenario: Missing checkout

- **WHEN** a patch pin matches a `GIT_CRATES` entry and that entry's unpacked directory has no `Cargo.toml`
- **THEN** `src_prepare` dies
- **AND** the build does not continue into `src_compile`

### Requirement: DesignCraft keeps direct git dependencies

DesignCraft `src_prepare` SHALL leave workspace git dependencies that sit outside `[patch.*]` unchanged.

#### Scenario: Craft-libs pins stay git dependencies

- **WHEN** `src_prepare` runs on a manifest whose `[workspace.dependencies]` pins `craft-print` and `craft-ui` by git rev and whose `[patch.crates-io]` pins `hayro` and `winit` by git rev
- **THEN** the `craft-print` and `craft-ui` lines stay git dependencies
- **AND** the `hayro` and `winit` lines become path dependencies
