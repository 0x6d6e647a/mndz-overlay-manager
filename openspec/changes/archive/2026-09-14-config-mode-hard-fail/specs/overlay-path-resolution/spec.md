## MODIFIED Requirements

### Requirement: Config is loaded for every non-help invocation

When a work subcommand (`list`, `outdated`, `update`, or any future command that performs overlay work) is invoked, the program SHALL load the TOML configuration file (from `--config` if supplied, otherwise the XDG default path), decode required key `overlay-path`, and decode optional keys `assets-path` and `github-token` when present. The program SHALL fail with an error-level log and exit status `1` if the file is missing, unreadable, not exactly mode `0600`, has a mode that cannot be read, or is missing the required `overlay-path` key. Absence of optional keys SHALL NOT fail config load by itself. The program SHALL NOT accept legacy keys `mndz-overlay-path` or `mndz-overlay-assets-path` as substitutes for the new names. Paths that only render help (top-level `--help` / `-h`, bare invocation that only shows help, or `COMMAND --help` / `-h`) SHALL NOT load configuration.

#### Scenario: Missing config file

- **WHEN** the user runs a work subcommand and the resolved config file does not exist
- **THEN** the program logs an error containing the attempted path
- **AND** the program exits with status `1`

#### Scenario: Config missing overlay-path

- **WHEN** the config file exists but does not define `overlay-path`
- **THEN** the program logs an error describing the missing key
- **AND** the program exits with status `1`

#### Scenario: Config mode is not 0600

- **WHEN** the user runs a work subcommand and the resolved config file exists with mode other than `0600`
- **THEN** the program logs an error naming the path and expected mode `0600`
- **AND** the program exits with status `1`

#### Scenario: Optional assets path omitted

- **WHEN** the config file defines `overlay-path` but omits `assets-path`
- **THEN** config load succeeds and the assets path is treated as unset until a command requires it

#### Scenario: Optional github-token omitted

- **WHEN** the config file defines `overlay-path` but omits `github-token`
- **THEN** config load succeeds and the token is resolved from the environment if present

#### Scenario: Legacy mndz-overlay-path key is not accepted

- **WHEN** the config file defines `mndz-overlay-path` but does not define `overlay-path`
- **THEN** the program fails config load as missing the required `overlay-path` key
- **AND** the program exits with status `1`
