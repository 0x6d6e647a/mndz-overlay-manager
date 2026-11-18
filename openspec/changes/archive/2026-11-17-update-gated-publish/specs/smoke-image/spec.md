# Spec Delta

## MODIFIED Requirements

### Requirement: Smoke uses its own image

`smoke` containers, including the gated smoke runs of `update`, SHALL start from the image tagged `mndz-overlay-manager/smoke:local`. Smoke containers SHALL NOT start from the materialize image, and `MNDZ_MATERIALIZE_IMAGE` SHALL NOT affect them. `update` SHALL build or use the smoke image only when at least one unit needs work. `outdated` and `gencache` SHALL NOT build or use the smoke image.

#### Scenario: Materialize override is ignored

- **WHEN** `MNDZ_MATERIALIZE_IMAGE` is set and the operator runs `smoke`
- **THEN** smoke containers are created from `mndz-overlay-manager/smoke:local`

#### Scenario: Update does not build it

- **WHEN** the operator runs `update` on a host with no smoke image and no selected package needs work
- **THEN** no smoke image is built

#### Scenario: Update with work builds it

- **WHEN** the operator runs `update` on a host with no smoke image and a package needs work
- **THEN** the smoke image is built before that unit's first gated run

#### Scenario: Gated runs ignore the materialize override

- **WHEN** `MNDZ_MATERIALIZE_IMAGE` is set and `update` gates a unit
- **THEN** the gated run containers are created from `mndz-overlay-manager/smoke:local`

### Requirement: When the smoke image is built

`smoke`, and `update` when it needs the smoke image, SHALL build the image when no image is recorded, when the recorded image id no longer exists in Docker, when the recorded generator identity differs from the program's, or when the base check finds a different stage3 digest. Otherwise it SHALL reuse the recorded image. A changed managed tree commit alone SHALL NOT cause a build.

#### Scenario: Recorded image is reused

- **WHEN** the recorded image exists, its generator identity matches, and the base check is not due
- **THEN** `smoke` does not run `docker build`

#### Scenario: Tree moved

- **WHEN** only the managed tree commit differs from the one in the sidecar
- **THEN** `smoke` does not run `docker build`

#### Scenario: Recipe changed

- **WHEN** the sidecar's generator identity differs from the program's
- **THEN** `smoke` builds a new image before any run

#### Scenario: Update reuses the recorded image

- **WHEN** `update` needs the smoke image and the recorded image exists with a matching generator identity
- **THEN** `update` does not run `docker build` for the smoke image

### Requirement: Smoke image failures stop the command

A host architecture with no official stage3 flavor, a failed `docker build`, or a registry failure on a host with no recorded image SHALL make `smoke` exit with status `1` before any run, with an error naming the cause. In `update`, the same failures SHALL be treated as specified by `update-smoke-gate` for unready gate prerequisites. No unit SHALL be published or committed, and the command SHALL exit with status `1`.

#### Scenario: Build fails

- **WHEN** `docker build` of the smoke image exits non-zero
- **THEN** `smoke` exits with status `1` and no run is performed

#### Scenario: Build fails during update

- **WHEN** `update` needs the smoke image and its `docker build` exits non-zero
- **THEN** no unit of that command is committed and `update` exits with status `1` naming the cause
