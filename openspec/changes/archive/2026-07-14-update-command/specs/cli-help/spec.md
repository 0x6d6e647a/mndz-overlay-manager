## ADDED Requirements

### Requirement: Help enumerates update subcommand

The top-level usage/help text SHALL list the `update` subcommand among available commands so users can discover package upgrading alongside `list`, `outdated`, and `help`.

#### Scenario: Help mentions update

- **WHEN** the user runs the program with `--help` or the `help` subcommand
- **THEN** the usage text includes the `update` subcommand
