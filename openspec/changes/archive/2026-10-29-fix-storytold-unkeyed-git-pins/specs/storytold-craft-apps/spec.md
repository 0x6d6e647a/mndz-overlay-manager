# Spec Delta

## MODIFIED Requirements

### Requirement: EffectCraft keeps Linux git crates

EffectCraft's Linux git dependencies SHALL remain in `GIT_CRATES`. Windows-only and wasm-only git crates SHALL be omitted.

#### Scenario: Filmcraft pins survive on Linux

- **WHEN** the EffectCraft ebuild is inspected after a Cargo rewrite
- **THEN** `GIT_CRATES` includes the Linux `filmcraft-*` git crates from that tag's lock
- **AND** `GIT_CRATES` omits windows-only and wasm-only git crates

#### Scenario: Crates also named by wasm or Windows stay

- **WHEN** the EffectCraft ebuild is inspected after a Cargo rewrite of a tag whose Linux set depends on `egui`, `eframe`, and `craft-update`, and a `wasm32` or Windows target table also names those packages
- **THEN** `GIT_CRATES` includes `egui`, `eframe`, and `craft-update`

### Requirement: Storytold craft apps rewrite patch-table git pins

A Storytold craft app `src_prepare` SHALL rewrite every one-line `[patch.*]` git pin whose crate name and `rev` match a `GIT_CRATES` entry, or match exactly one package `Cargo.toml` inside a checkout already fetched for that `rev`, onto the Portage work directory plus that crate directory, with `%commit%` replaced by the commit. Non-source keys on that pin, including `version` and `features`, SHALL remain. The ebuild `src_prepare` SHALL NOT contain that commit as a literal.

#### Scenario: Hayro follows the pdfcraft checkout

- **WHEN** `GIT_CRATES` records `hayro` at commit `b5467d93a0ffaa5e5e6658bccdf8655a3ba689c9` with directory `pdfcraft-%commit%/vendor/hayro` and `[patch.crates-io]` pins `hayro` at that rev
- **THEN** `src_prepare` rewrites that line to the unpacked `pdfcraft-b5467d93a0ffaa5e5e6658bccdf8655a3ba689c9/vendor/hayro` path
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

#### Scenario: Unused egui member follows the fetched archive

- **WHEN** `GIT_CRATES` records `ecolor` at commit `6d518fc799681571963842f95b55a6b68431b15a` with directory `egui-%commit%/crates/ecolor`, does not record `egui_system_font_provider`, and `[patch.crates-io]` pins `egui_system_font_provider` at that rev
- **AND** the unpacked `egui-6d518fc799681571963842f95b55a6b68431b15a` tree contains `crates/egui_system_font_provider/Cargo.toml` whose package name is `egui_system_font_provider`
- **THEN** `src_prepare` rewrites that pin to the unpacked `egui-6d518fc799681571963842f95b55a6b68431b15a/crates/egui_system_font_provider` path
- **AND** the ebuild `src_prepare` does not contain that commit as a literal

### Requirement: Storytold craft apps reject an unresolvable patch pin

A Storytold craft app `src_prepare` SHALL die before `src_compile` when a one-line `[patch.*]` git pin's package is absent from `GIT_CRATES` and from every checkout already fetched for that `rev`, when more than one such checkout contains that package, when the chosen directory has no `Cargo.toml`, or when a `[patch.*]` git pin is not a one-line `rev` assignment the rewrite can parse.

#### Scenario: Missing GIT_CRATES entry

- **WHEN** a one-line `[patch.*]` git pin names a crate and rev that `GIT_CRATES` does not record
- **AND** no checkout already fetched for that rev contains that package's `Cargo.toml`
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

#### Scenario: Two checkouts contain the same package

- **WHEN** a one-line `[patch.*]` git pin names a crate and rev that `GIT_CRATES` does not record
- **AND** two checkouts already fetched for that rev each contain that package's `Cargo.toml`
- **THEN** `src_prepare` dies
- **AND** the build does not continue into `src_compile`

## ADDED Requirements

### Requirement: Storytold craft apps register a fetched direct git package

When the lock records a workspace git dependency that sits outside `[patch.*]` as a git source at a `rev` absent from `GIT_CRATES`, and exactly one checkout already fetched for that `rev` contains that package's `Cargo.toml`, Cargo's git config for that build SHALL point the package at that directory before `src_compile`. The workspace line SHALL remain a git dependency. When the lock does not record that package, `src_prepare` SHALL leave it unregistered and SHALL NOT die.

#### Scenario: Missing craft-update is taken from the fetched craft-libs tree

- **WHEN** the lock records `craft-update` as a git source at commit `92d392cff132eaf53e13afff77f38b5c11b73aa0`, `GIT_CRATES` records other crates from that commit and does not record `craft-update`, and the workspace pins `craft-update` at that rev outside `[patch.*]`
- **AND** the unpacked craft-libs tree contains `crates/update/Cargo.toml` whose package name is `craft-update`
- **THEN** the workspace `craft-update` line stays a git dependency
- **AND** Cargo's git config points `craft-update` at that `crates/update` directory before `src_compile`

#### Scenario: Unlocked workspace git dependency stays unregistered

- **WHEN** a workspace git dependency outside `[patch.*]` is absent from `GIT_CRATES`
- **AND** the lock does not record that package
- **THEN** `src_prepare` leaves that package unregistered
- **AND** `src_prepare` does not die

### Requirement: Storytold craft apps reject a lock git package with no checkout

When the lock records a workspace git dependency that sits outside `[patch.*]` as a git source at a `rev` absent from `GIT_CRATES`, `src_prepare` SHALL die before `src_compile` when no checkout already fetched for that `rev` contains that package's `Cargo.toml`, and when more than one such checkout contains it. The workspace line SHALL remain unchanged.

#### Scenario: Lock git package with no checkout dies

- **WHEN** the lock records a workspace git dependency as a git source at a rev that `GIT_CRATES` does not record
- **AND** no checkout already fetched for that rev contains that package's `Cargo.toml`
- **THEN** `src_prepare` dies
- **AND** the workspace line is left unchanged
- **AND** the build does not continue into `src_compile`

#### Scenario: Two checkouts contain the direct git package

- **WHEN** the lock records a workspace git dependency as a git source at a rev that `GIT_CRATES` does not record
- **AND** two checkouts already fetched for that rev each contain that package's `Cargo.toml`
- **THEN** `src_prepare` dies
- **AND** the workspace line is left unchanged
- **AND** the build does not continue into `src_compile`
