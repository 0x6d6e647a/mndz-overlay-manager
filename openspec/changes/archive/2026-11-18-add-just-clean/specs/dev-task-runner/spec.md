# Spec Delta

## ADDED Requirements

### Requirement: Clean Just build outputs

The task runner SHALL provide `just clean [flavor]`. It SHALL accept `dev`, `release`, `coverage-dev`, `coverage-release`, or `all`, and SHALL default to `dev`. A named flavor SHALL remove only its corresponding `dist/<flavor>/` tree. The `all` selection SHALL remove only the four named flavor trees and `coverage/`.

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

- **WHEN** a contributor runs `just clean all`
- **THEN** the four flavor trees and shared coverage reports are removed and `dist-newstyle/` and other repository outputs are preserved

### Requirement: Cleanup validates selection and tolerates absent outputs

The cleanup recipe SHALL fail before deleting any files if the selection is unsupported. It SHALL succeed when the selected output paths are already absent.

#### Scenario: Invalid selection leaves outputs intact

- **WHEN** a contributor passes an unsupported flavor or path-like argument
- **THEN** cleanup exits unsuccessfully and removes nothing

#### Scenario: Repeated cleanup succeeds

- **WHEN** a contributor repeats a successful cleanup before rebuilding
- **THEN** cleanup succeeds with the selected paths still absent
