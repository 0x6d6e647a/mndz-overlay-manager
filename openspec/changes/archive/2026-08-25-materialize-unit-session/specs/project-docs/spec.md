## ADDED Requirements

### Requirement: README documents live materialize container names

`README.md` SHALL document at operator depth that during full-path DepsAndAssets materialize the program keeps a named Docker container for that unit (name prefixed `mndz-mat-`, including run id, category, package, and PV) so `docker stats` / `docker exec` can target it **while the unit runs**, and that the container is removed when the unit ends (`--rm` / `docker rm`). The text SHALL NOT tell operators to drop `--rm` or keep failed containers for debugging; retained unit `work/` on hard-fail remains the investigation artifact as specified by `temp-workspace`.

#### Scenario: Operator finds named session guidance

- **WHEN** an operator reads `README.md` materialize image or `update` documentation
- **THEN** the text states that a running full-path unit has a `mndz-mat-…` container visible to `docker ps` / `docker stats`
- **AND** that the container is removed when that unit finishes
