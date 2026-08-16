## REMOVED Requirements

### Requirement: Warn when config file mode is not 0600

**Reason:** A world-readable overlay-manager TOML can hold `github-token`. A warning printed outside the logger that still continues with exit `0` does not treat that as a config-load failure.

**Migration:** Use the replacement requirement “Hard-fail when config file mode is not 0600.” Operators whose file is not exactly `0600` run `chmod 600` on that path before the next work command.

## ADDED Requirements

### Requirement: Hard-fail when config file mode is not 0600

When a work command (`list`, `outdated`, `update`, `gencache`, `eclean`, or any other command that loads the overlay-manager configuration file) successfully locates that file, the program SHALL inspect the file’s permission bits before using the file contents. If the mode is not exactly `0600` (owner read/write only), or the mode cannot be read, the program SHALL log an error that names the path and states that the expected mode is `0600`, and SHALL exit with status `1` without loading or using that file. If the mode is exactly `0600`, the program SHALL NOT emit this permission error solely for that file.

Help-only paths that do not load configuration SHALL NOT emit this error.

The program SHALL NOT change GitHub token resolution order or reject a `github-token` key solely because of this requirement.

#### Scenario: World-readable config hard-fails

- **WHEN** the operator runs `update` and the located config file is mode `0644`
- **THEN** the program logs an error naming that path and expected mode `0600`
- **AND** the program exits with status `1` without using that file

#### Scenario: Unreadable mode hard-fails

- **WHEN** the operator runs a work command and the located config file exists but its permission bits cannot be read
- **THEN** the program logs an error naming that path and expected mode `0600`
- **AND** the program exits with status `1` without using that file

#### Scenario: Mode 0600 is silent

- **WHEN** the located config file is mode `0600`
- **THEN** the program does not emit the config-permission error solely for that file
- **AND** the program continues config load

#### Scenario: Help does not check

- **WHEN** the operator runs `--help` without a work command
- **THEN** the program does not load the config file and does not emit the config-permission error
