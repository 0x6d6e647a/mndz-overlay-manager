# storytold-craft-apps Delta

## ADDED Requirements

### Requirement: Storytold craft apps rewrite patch-table git pins

A Storytold craft app `src_prepare` SHALL rewrite every one-line `[patch.*]` git pin whose crate name and `rev` equal a `GIT_CRATES` entry onto the Portage work directory plus that entry's directory, with `%commit%` replaced by the commit. Non-source keys on that pin, including `version` and `features`, SHALL remain. The ebuild `src_prepare` SHALL NOT contain that commit as a literal.

#### Scenario: Hayro follows the pdfcraft checkout

- **WHEN** `GIT_CRATES` records `hayro` at commit `b5467d93a0ffaa5e5e6658bccdf8655a3ba689c9` with directory `pdfcraft-%commit%/vendor/hayro` and `[patch.crates-io]` pins `hayro` at that rev
- **THEN** `src_prepare` rewrites that line to the unpacked `pdfcraft-b5467d93a0ffaa5e6658bccdf8655a3ba689c9/vendor/hayro` path
- **AND** the ebuild `src_prepare` does not contain that commit as a literal

#### Scenario: Winit follows its checkout

- **WHEN** `GIT_CRATES` records `winit` at commit `3d51077fd1a966f84df9ef287839dc84fd5b4ca7` and `[patch.crates-io]` pins `winit` at that rev on a URL that ends in `.git`
- **THEN** `src_prepare` rewrites that line to the unpacked `winit-3d51077fd1a966f84df9ef287839dc84fd5b4ca7` path

#### Scenario: Repeated patch lines

- **WHEN** more than one `[patch.*]` line names the same crate at the `GIT_CRATES` commit
- **THEN** `src_prepare` rewrites every such line to that entry's unpacked path

#### Scenario: Version key stays on the pin

- **WHEN** `GIT_CRATES` records `krilla` at commit `c3487320b2d1de657b860b3c8abb44e1f2b32bd8` with directory `craft-libs-%commit%/vendor/krilla` and `[patch.crates-io]` pins `krilla` at that rev with `version = "=0.8.2"`
- **THEN** `src_prepare` rewrites that line to the unpacked `craft-libs-c3487320b2d1de657b860b3c8abb44e1f2b32bd8/vendor/krilla` path
- **AND** the rewritten pin still sets `version = "=0.8.2"`

### Requirement: Storytold craft apps reject an unresolvable patch pin

A Storytold craft app `src_prepare` SHALL die before `src_compile` when a one-line `[patch.*]` git pin has no `GIT_CRATES` entry for that crate name and `rev`, when the rewritten checkout has no `Cargo.toml`, or when a `[patch.*]` git pin is not a one-line `rev` assignment the rewrite can parse.

#### Scenario: Missing GIT_CRATES entry

- **WHEN** a one-line `[patch.*]` git pin names a crate and rev that `GIT_CRATES` does not record
- **THEN** `src_prepare` dies
- **AND** the build does not continue into `src_compile`

#### Scenario: Missing checkout

- **WHEN** a patch pin matches a `GIT_CRATES` entry and that entry's unpacked directory has no `Cargo.toml`
- **THEN** `src_prepare` dies
- **AND** the build does not continue into `src_compile`

#### Scenario: Unparsed pin dies

- **WHEN** a `[patch.*]` git pin uses `branch` or `tag` instead of `rev`, or the pin is not a one-line assignment
- **THEN** `src_prepare` dies
- **AND** the build does not continue into `src_compile`

### Requirement: Storytold craft apps keep direct git dependencies

A Storytold craft app `src_prepare` SHALL leave workspace git dependencies that sit outside `[patch.*]` unchanged.

#### Scenario: Craft-libs pins stay git dependencies

- **WHEN** `src_prepare` runs on a manifest whose `[workspace.dependencies]` pins `craft-print` and `craft-ui` by git rev and whose `[patch.crates-io]` pins `hayro` and `winit` by git rev
- **THEN** the `craft-print` and `craft-ui` lines stay git dependencies
- **AND** the `hayro` and `winit` lines become path dependencies

#### Scenario: Direct craft-pdf pin stays a git dependency

- **WHEN** `src_prepare` runs on a manifest whose workspace dependencies pin `craft-pdf` by git rev and whose `[patch.crates-io]` pins `krilla` at the same rev
- **THEN** the `craft-pdf` line stays a git dependency
- **AND** the `krilla` line becomes a path dependency

## REMOVED Requirements

### Requirement: DesignCraft rewrites patch-table git pins

**Reason**: The same rewrite applies to every Storytold craft app, not only DesignCraft.
**Migration**: Use "Storytold craft apps rewrite patch-table git pins".

### Requirement: DesignCraft rejects an unresolvable patch pin

**Reason**: The same failure applies to every Storytold craft app, not only DesignCraft.
**Migration**: Use "Storytold craft apps reject an unresolvable patch pin".

### Requirement: DesignCraft keeps direct git dependencies

**Reason**: Direct git dependencies stay unchanged for every Storytold craft app, not only DesignCraft.
**Migration**: Use "Storytold craft apps keep direct git dependencies".
