## MODIFIED Requirements

### Requirement: Docker is mandatory for full path

When at least one classified unit is full path and will mutate, preflight SHALL require `docker` on `PATH`. A usable product materialize image SHALL be provided by `ensure-materialize-image` (build or reuse) unless `MNDZ_MATERIALIZE_IMAGE` names an override tag, in which case that tag MUST already be usable. Missing Docker, a failed ensure, or an unusable override image SHALL log an error and fail those full-path units (or exit with status `1` before their mutation) as specified by `ensure-materialize-image` and `update-command`. The program SHALL NOT fall back to host `go`, `npm`, `bun`, `sbcl`, `pycargoebuild`, or other host language toolchains for that full-path work. The program SHALL NOT require the operator to run `docker build` as a prerequisite of `update` when the default product tag is used.

#### Scenario: No docker hard-fails before mutate

- **WHEN** `update` will full-path materialize at least one unit and `docker` is not on `PATH`
- **THEN** the program exits with status `1` before overlay or assets mutation of those units and does not run host `go`/`npm`/`bun` instead

#### Scenario: Reuse-only update does not require docker

- **WHEN** every DepsAndAssets unit that needs work is classified reuse
- **THEN** preflight does not fail solely because `docker` is missing

#### Scenario: Missing default image is ensured not a recipe-only fail

- **WHEN** `update` will full-path materialize at least one unit, `docker` is on `PATH`, the default product tag is missing, and `MNDZ_MATERIALIZE_IMAGE` is unset
- **THEN** the program ensures the image (generate and `docker build`) rather than only printing a manual `docker build` command as the hard-fail
