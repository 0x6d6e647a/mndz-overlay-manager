# Spec Delta

## ADDED Requirements

### Requirement: FigCraft joins the craft inventory

The overlay SHALL ship `media-gfx/figcraft` from GitHub owner `storytold`, repository `figcraft`, tag prefix `v`. The primary `SRC_URI` SHALL be that tag archive. The ebuild SHALL NOT use a crates.io `.crate` as its primary source.

#### Scenario: FigCraft is present

- **WHEN** the overlay inventory is inspected
- **THEN** it contains `media-gfx/figcraft`
- **AND** its primary `SRC_URI` fetches `https://github.com/storytold/figcraft/archive/refs/tags/v${PV}.tar.gz`
- **AND** that primary `SRC_URI` does not download a crates.io `.crate`

### Requirement: FigCraft omits the collaboration server

FigCraft SHALL compile and install only the programs selected by `gui` and `cli`. It SHALL NOT install `figcraft-server`. Workspace `src_test` SHALL exclude `figcraft-web` and `xtask` and SHALL NOT exclude `figcraft-server`.

#### Scenario: Server binary is absent

- **WHEN** FigCraft is installed with default USE
- **THEN** `/usr/bin/figcraft` and `/usr/bin/figcraft-cli` exist
- **AND** `/usr/bin/figcraft-server` does not exist

#### Scenario: Workspace tests still include the server crate

- **WHEN** `USE=test` and `FEATURES=test` run `src_test` for FigCraft
- **THEN** the phase excludes `figcraft-web` and `xtask`
- **AND** the phase does not exclude `figcraft-server`
- **AND** the phase does not pass a package selection that omits the library crates
