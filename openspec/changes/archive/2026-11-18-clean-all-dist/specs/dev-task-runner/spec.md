## MODIFIED Requirements

### Requirement: Clean Just build outputs

The task runner SHALL provide `just clean [flavor]`. It SHALL accept `dev`, `release`, `coverage-dev`, `coverage-release`, or `all`, and SHALL default to `dev`. A named flavor SHALL remove only its corresponding `dist/<flavor>/` tree, and the parent `dist/` directory can remain empty. The `all` selection SHALL recursively remove `dist/` and `coverage/`. Every selection SHALL preserve `dist-newstyle/`.

#### Scenario: Default cleanup targets dev

- **WHEN** a contributor runs `just clean` or `just clean dev`
- **THEN** the dev build tree is removed and the other flavor trees and coverage reports are preserved

#### Scenario: Release cleanup removes collected HIE

- **WHEN** a contributor runs `just clean release`
- **THEN** the release build tree and its collected HIE are removed and the other flavor trees and coverage reports are preserved

#### Scenario: Each coverage flavor can be cleaned independently

- **WHEN** a contributor runs `just clean coverage-dev` or `just clean coverage-release`
- **THEN** only the selected flavor tree is removed and shared coverage reports are preserved

#### Scenario: All cleans Just workflow outputs

- **WHEN** a contributor runs `just clean all` with an extra entry under `dist/`
- **THEN** the entire `dist/` tree, including the extra entry, and the entire `coverage/` tree are removed and `dist-newstyle/` and other repository outputs are preserved
