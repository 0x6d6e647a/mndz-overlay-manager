## ADDED Requirements

### Requirement: Full-path unit paths are bind-mounted into the container

When a full-path unit directory is opened and materialize runs in the Docker container specified by `hermetic-asset-materialize`, the program SHALL bind-mount that unit’s `work/` and `out/` directories into the container at the **same absolute paths** the host created (the paths the disk-space gate measured on the effective temp root). The container SHALL NOT copy the unit tree to a different path for pack output. Reuse-path units SHALL NOT require this bind-mount.

#### Scenario: Container out is host out

- **WHEN** full-path materialize for `dev-util/crush` `0.77.0` writes `crush-0.77.0-vendor.tar.xz`
- **THEN** that file appears at the host unit `out/` path under `<run-root>/dev-util/crush/0.77.0-full/out/`
