## ADDED Requirements

### Requirement: CLI entrypoint supports subcommands and global options
The program SHALL be invoked as `mndz-overlay-mgr` and SHALL accept subcommands for future tools. It SHALL support the global options `--config <FILE.toml>`, `-v`/`--verbose` (repetition increases log level), and `--log-level <error|warn|info|debug>`.

#### Scenario: Running with no arguments shows help
- **WHEN** the program is invoked with no arguments
- **THEN** it displays the main help text listing available subcommands and global options and exits with status 0

#### Scenario: Top-level help never requires config
- **WHEN** the user runs `mndz-overlay-mgr help`, `--help`, or `-h`
- **THEN** the program displays main help and exits without attempting to load any configuration file
