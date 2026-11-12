# Spec Delta

## ADDED Requirements

### Requirement: Generated image provides GNU time

The generated recipe SHALL install `sys-process/time` in the base Portage step so that `/usr/bin/time` in the image is GNU Time. The recipe generator identity SHALL change with this addition, so an image recorded by an earlier generator is a miss and is rebuilt.

#### Scenario: Recipe installs time

- **WHEN** ensure generates a Dockerfile for the default product tag
- **THEN** the base Portage `RUN` emerges `sys-process/time`

#### Scenario: Pre-time image is rebuilt

- **WHEN** the sidecar records an image built by the previous generator identity
- **THEN** ensure treats it as a miss and builds the default tag again

### Requirement: Materialize session requires GNU time when recording

When run metrics are recording and a materialize container session starts, the program SHALL verify that `/usr/bin/time` inside the container is GNU Time, once per session. If it is not, that unit SHALL hard-fail with an error naming the image and `--no-metrics`. With `--no-metrics` this check SHALL NOT run.

#### Scenario: Override image without time

- **WHEN** `MNDZ_MATERIALIZE_IMAGE` names an image that lacks GNU time and `update` full-path materializes a unit with metrics on
- **THEN** that unit hard-fails with an error naming the image and `--no-metrics`
- **AND** the program does not `docker build` the override tag

#### Scenario: Opt-out skips the check

- **WHEN** the same override image is used with `update --no-metrics`
- **THEN** the session does not fail for lack of GNU time
