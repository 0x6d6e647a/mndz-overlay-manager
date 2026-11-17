# Spec Delta

## MODIFIED Requirements

### Requirement: Smoke help describes what a run does

`smoke --help` SHALL state that every on-disk version of each selected package is installed in a fresh Docker container and checked, that runs happen one at a time, that `--jobs` sets the build parallelism inside the container, and that the command needs Docker with the containerd image store. It SHALL NOT document `--refresh`.

#### Scenario: Smoke help content

- **WHEN** the user runs `smoke --help`
- **THEN** the usage text describes optional `PACKAGE...` targets and states that omitting targets tests all discovered packages
- **AND** the text mentions `--jobs` as build parallelism
- **AND** the text does not mention `--refresh`
- **AND** the program exits with status `0` without loading configuration

## ADDED Requirements

### Requirement: Smoke help documents the compile cache flags

`smoke --help` SHALL document `--no-compile-cache` as running without the per-package compile cache and `--reset-compile-cache` as deleting the selected packages' compile caches before their runs.

#### Scenario: Compile cache flags in help

- **WHEN** the user runs `smoke --help`
- **THEN** the usage text documents `--no-compile-cache` and `--reset-compile-cache`
