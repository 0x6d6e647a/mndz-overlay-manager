# Spec Delta

## MODIFIED Requirements

### Requirement: Full-path unit paths are bind-mounted into the container

When a full-path unit directory is opened and materialize runs in the Docker container specified by `hermetic-asset-materialize`, the program SHALL bind-mount **only** that unit’s `work/` and `out/` directories into the container at the **same absolute paths** the host created (the paths the disk-space gate measured on the effective temp root). When run metrics are recording, the program SHALL also bind-mount the run metrics directory’s `time/` subdirectory at the same absolute path, so inner time files land on the host. The program SHALL NOT bind-mount the run root, sibling unit directories, other packages’ trees, or the rest of the run metrics directory solely to satisfy those paths. The container SHALL NOT copy the unit tree to a different path for pack output. Reuse-path units SHALL NOT require this bind-mount.

#### Scenario: Container out is host out

- **WHEN** full-path materialize for `dev-util/crush` `0.77.0` writes `crush-0.77.0-vendor.tar.xz`
- **THEN** that file appears at the host unit `out/` path under `<run-root>/dev-util/crush/0.77.0-full/out/`

#### Scenario: Sibling units are not mounted

- **WHEN** full-path materialize runs for `dev-util/mise` while another unit directory exists under the same run root
- **THEN** the mise session bind-mounts only that mise unit’s `work/` and `out/`
- **AND** it does not bind-mount the sibling unit directory or the run root as a whole

#### Scenario: Metrics time directory is mounted when recording

- **WHEN** full-path materialize runs with run metrics recording
- **THEN** the session also bind-mounts the run metrics `time/` directory at its host path
- **AND** it does not bind-mount `run.jsonl` or the metrics directory as a whole

#### Scenario: No metrics mount when opted out

- **WHEN** full-path materialize runs under `update --no-metrics`
- **THEN** the session bind-mounts only that unit’s `work/` and `out/`
