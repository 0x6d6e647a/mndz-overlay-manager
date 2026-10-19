# Spec Delta

## ADDED Requirements

### Requirement: Uv ecosystem floor

When no Manifest `DIST` size and no release-asset size is available, a Uv full-path estimate and a Uv reuse-without-size estimate SHALL use a documented Uv floor. That floor SHALL be a named product constant greater than zero, applied on the same path as the other ecosystem floors, including the fixed 256 MiB safety margin.

#### Scenario: Missing baseline uses the Uv floor

- **WHEN** a Uv full-path unit has no matching Manifest `DIST` size and no release-asset size
- **THEN** the need estimate uses the Uv floor plus the 256 MiB margin
