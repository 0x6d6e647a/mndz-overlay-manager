## ADDED Requirements

### Requirement: Top-level help catalogs eclean and distfiles-path

Top-level usage/help SHALL list `eclean` among work commands with a one-line description that it cleans the manager distfiles cache. Top-level help SHALL document the global option `--distfiles-path` (or equivalent long option name used by the parser) for overriding the manager distfiles directory.

#### Scenario: Top-level help names eclean

- **WHEN** the user runs the program with `--help`
- **THEN** the top-level usage text lists `eclean` among available work commands

#### Scenario: Top-level help names distfiles-path option

- **WHEN** the user runs the program with `--help`
- **THEN** the top-level usage text documents `--distfiles-path`

### Requirement: eclean help describes manager cache only

The `eclean` subcommand SHALL support `--help` / `-h` that describe deleting the manager private distfiles cache (default under XDG cache `mndz/overlay-manager/distfiles`), note that system Portage distfiles are not cleaned, and note that global options such as `--distfiles-path` are supplied before the subcommand.

#### Scenario: eclean help succeeds

- **WHEN** the user runs `eclean --help`
- **THEN** the usage text describes cleaning the manager distfiles cache
- **AND** the program exits with status `0` without requiring a valid overlay

## MODIFIED Requirements

### Requirement: Per-command help is detailed and flag-only

Each work subcommand (`list`, `outdated`, `update`, `gencache`, `eclean`) SHALL support `--help` and `-h` that render command-scoped usage (that command’s arguments and local options when any exist), a brief description of the command’s behaviour, and a note that global options are supplied before the subcommand and are documented by top-level `--help`. Per-command help SHALL NOT be provided via a positional `help` subcommand.

#### Scenario: Update help documents package targets

- **WHEN** the user runs `update --help`
- **THEN** the usage text describes optional `PACKAGE...` targets (`category/package` or unambiguous package name)
- **AND** the usage text states that omitting targets updates packages that need work
- **AND** the program exits with status `0` without loading configuration
