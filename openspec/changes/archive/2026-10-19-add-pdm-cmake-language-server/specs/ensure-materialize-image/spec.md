# Spec Delta

## ADDED Requirements

### Requirement: Pdm image installs Python and pdm

When a full-path Pdm unit needs the materialize image, the recipe SHALL emerge the chosen `dev-lang/python` slot and `dev-python/pdm` from Portage. That unit SHALL NOT add Rust or `dev-python/uv` to the image. The recipe SHALL NOT install CPython or pdm from an upstream tarball. When `dev-python/pdm` is not plain-visible on the host architecture, the recipe SHALL write a package-level `package.accept_keywords` entry for it and SHALL NOT set whole-image `ACCEPT_KEYWORDS` to `~arch`.

#### Scenario: Portage supplies the Pdm toolchain

- **WHEN** the recipe is generated for a Pdm floor that needs Python `3.12`
- **THEN** the recipe emerges `dev-lang/python` slot `3.12` and `dev-python/pdm`
- **AND** the recipe does not emerge Rust or `dev-python/uv` for that unit
- **AND** the recipe does not download a CPython or pdm tarball from an upstream project URL

#### Scenario: Host interpreter is not the image slot

- **WHEN** the chosen slot is `3.12` and the host has no Python `3.12` interpreter
- **THEN** the recipe still emerges `dev-lang/python` slot `3.12`

#### Scenario: Testing keywords stay on the pdm atom

- **WHEN** the `dev-python/pdm` ebuild that meets the floor is not plain-visible
- **THEN** the recipe writes package-level `package.accept_keywords` for `dev-python/pdm`
- **AND** the recipe does not set whole-image `ACCEPT_KEYWORDS` to `~arch`

### Requirement: Pdm emerge accepts dependency keywords

When `dev-python/pdm` is not plain-visible, the pdm emerge SHALL pass `--autounmask=y --autounmask-continue=y`. Keyword-masked dependencies of that emerge SHALL be accepted at package level inside the image.

#### Scenario: Dependency keywords stay package-level

- **WHEN** the `dev-python/pdm` ebuild that meets the floor is not plain-visible
- **THEN** the pdm emerge passes `--autounmask=y --autounmask-continue=y`
- **AND** the recipe does not set whole-image `ACCEPT_KEYWORDS` to `~arch`
