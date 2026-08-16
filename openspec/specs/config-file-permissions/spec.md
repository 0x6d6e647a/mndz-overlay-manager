# config-file-permissions Specification

## Purpose

Work commands that load the overlay-manager TOML hard-fail when the file is not exactly mode `0600` or its mode cannot be read, so a world-readable config cannot be used. Token resolution is unchanged.

## Requirements

### Requirement: Warn when config file mode is not 0600

When a work command (`list`, `outdated`, `update`, `gencache`, `eclean`, or any other command that loads the overlay-manager configuration file) successfully locates that file, the program SHALL inspect the file’s permission bits. If the mode is not exactly `0600` (owner read/write only), the program SHALL log a warning that names the path and states that the expected mode is `0600`. The program SHALL still load and use a readable file whose mode is not `0600`. The program SHALL NOT hard-fail solely because the mode is not `0600`. Help-only paths that do not load configuration SHALL NOT emit this warning.

The program SHALL NOT change GitHub token resolution order or reject a `github-token` key solely because of this requirement.

#### Scenario: World-readable config warns and continues

- **WHEN** the operator runs `update` and the loaded config file is mode `0644`
- **THEN** the program logs a warning naming that path and expected mode `0600` and continues the command

#### Scenario: Mode 0600 is silent

- **WHEN** the loaded config file is mode `0600`
- **THEN** the program does not emit the config-permission warning solely for that file

#### Scenario: Help does not warn

- **WHEN** the operator runs `--help` without a work command
- **THEN** the program does not load the config file and does not emit the config-permission warning
