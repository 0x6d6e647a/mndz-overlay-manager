# Spec Delta

## ADDED Requirements

### Requirement: Uv image installs Python, Rust, and uv

When a full-path Uv unit needs the materialize image, the recipe SHALL emerge the chosen `dev-lang/python` slot, Rust, and `dev-python/uv` from Portage. Rust SHALL be emerged before `dev-python/uv`. The recipe SHALL NOT install CPython or uv from upstream tarball or zip URLs. Packing SHALL use the image `uv` and the image Python interpreter.

#### Scenario: Portage supplies the Uv toolchain

- **WHEN** the recipe is generated for a Uv floor that needs Python `3.14`
- **THEN** the recipe emerges `dev-lang/python` slot `3.14`, Rust, and `dev-python/uv`
- **AND** Rust is emerged before `dev-python/uv`
- **AND** the recipe does not download a CPython or uv tarball from an upstream project URL

#### Scenario: Packing uses the image interpreter

- **WHEN** full-path Uv packing runs in the image
- **THEN** it invokes the image `uv` with the emerged Python interpreter
