# overlay-test-use Delta

## ADDED Requirements

### Requirement: Storytold craft apps gate workspace cargo tests

Each Storytold craft app SHALL declare `IUSE` including `test` and set `RESTRICT` including `!test? ( test )`. When the test phase runs, `src_test` SHALL run the Cargo workspace tests excluding `<name>-web` and `xtask`. That phase SHALL NOT receive a package selection that limits it to the GUI or CLI package.

#### Scenario: test USE is present

- **WHEN** a live Storytold craft app ebuild is inspected
- **THEN** `IUSE` includes `test` and `RESTRICT` includes `!test? ( test )`

#### Scenario: Workspace tests are not narrowed to one binary

- **WHEN** `USE=test` and `FEATURES=test` run `src_test` for a Storytold craft app
- **THEN** the phase runs workspace tests excluding `<name>-web` and `xtask`
- **AND** the phase does not pass a package selection that omits the library crates
