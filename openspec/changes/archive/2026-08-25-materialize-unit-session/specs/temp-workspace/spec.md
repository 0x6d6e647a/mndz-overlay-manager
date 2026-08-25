## MODIFIED Requirements

### Requirement: Full-path unit paths are bind-mounted into the container

When a full-path unit directory is opened and materialize runs in the Docker container specified by `hermetic-asset-materialize`, the program SHALL bind-mount **only** that unit’s `work/` and `out/` directories into the container at the **same absolute paths** the host created (the paths the disk-space gate measured on the effective temp root). The program SHALL NOT bind-mount the run root, sibling unit directories, or other packages’ trees solely to satisfy those paths. The container SHALL NOT copy the unit tree to a different path for pack output. Reuse-path units SHALL NOT require this bind-mount.

#### Scenario: Container out is host out

- **WHEN** full-path materialize for `dev-util/crush` `0.77.0` writes `crush-0.77.0-vendor.tar.xz`
- **THEN** that file appears at the host unit `out/` path under `<run-root>/dev-util/crush/0.77.0-full/out/`

#### Scenario: Sibling units are not mounted

- **WHEN** full-path materialize runs for `dev-util/mise` while another unit directory exists under the same run root
- **THEN** the mise session bind-mounts only that mise unit’s `work/` and `out/`
- **AND** it does not bind-mount the sibling unit directory or the run root as a whole
