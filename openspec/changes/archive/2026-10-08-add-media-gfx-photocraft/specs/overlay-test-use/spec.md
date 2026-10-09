# overlay-test-use Delta

## ADDED Requirements

### Requirement: photocraft gates workspace cargo tests

`media-gfx/photocraft` SHALL declare `IUSE` including `test` and set `RESTRICT` including `!test? ( test )`. When the test phase runs, `src_test` SHALL run the Cargo workspace tests excluding `photocraft-web` and `xtask`. That phase SHALL NOT receive a package selection that limits it to the GUI or CLI package. Content-only gate fixes SHALL ship as revision bumps.

#### Scenario: test USE is present

- **WHEN** the live photocraft ebuild is inspected
- **THEN** `IUSE` includes `test` and `RESTRICT` includes `!test? ( test )`

#### Scenario: Workspace tests are not narrowed to one binary

- **WHEN** `USE=test` and `FEATURES=test` run `src_test`
- **THEN** the phase runs workspace tests excluding `photocraft-web` and `xtask`
- **AND** the phase does not pass a package selection that omits the library crates
