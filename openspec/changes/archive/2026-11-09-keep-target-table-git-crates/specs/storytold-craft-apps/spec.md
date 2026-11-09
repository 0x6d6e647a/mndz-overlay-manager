# Spec Delta

## MODIFIED Requirements

### Requirement: EffectCraft keeps Linux git crates

EffectCraft's Linux git dependencies SHALL remain in `GIT_CRATES`. A git crate named only from a windows-only or wasm-only target table SHALL remain.

#### Scenario: Filmcraft pins survive on Linux

- **WHEN** the EffectCraft ebuild is inspected after a Cargo rewrite
- **THEN** `GIT_CRATES` includes the Linux `filmcraft-*` git crates from that tag's lock

#### Scenario: Crates also named by wasm or Windows stay

- **WHEN** the EffectCraft ebuild is inspected after a Cargo rewrite of a tag whose Linux set depends on `egui`, `eframe`, and `craft-update`, and a `wasm32` or Windows target table also names those packages
- **THEN** `GIT_CRATES` includes `egui`, `eframe`, and `craft-update`

#### Scenario: A target-table-only git crate stays

- **WHEN** the EffectCraft ebuild is inspected after a Cargo rewrite of a tag whose lock git package is named only from a `wasm32` or windows target table
- **THEN** `GIT_CRATES` includes that package
