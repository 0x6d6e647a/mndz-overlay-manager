# Spec Delta

## ADDED Requirements

### Requirement: Full-path Pdm uses image pdm

Full-path Pdm materialize SHALL run `pdm` from the materialize image and SHALL point it at the image interpreter for the chosen slot. The container SHALL NOT use a host `pdm` binary and SHALL NOT download a Python interpreter. The first `pdm sync` for a Pdm package SHALL run in that container.

#### Scenario: Host pdm is unused

- **WHEN** full-path Pdm packing runs and the host has no `pdm` binary
- **THEN** the container uses the image `pdm` and does not download CPython

#### Scenario: Slot interpreter is explicit

- **WHEN** full-path Pdm packing runs for slot `3.12`
- **THEN** `pdm` is pointed at the image Python `3.12` interpreter
- **AND** `pdm` is not asked to install a Python interpreter
