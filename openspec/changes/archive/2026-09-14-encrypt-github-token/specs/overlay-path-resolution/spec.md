## MODIFIED Requirements

### Requirement: Config is loaded for every non-help invocation

When a work subcommand (`list`, `outdated`, `update`, `gencache`, `eclean`, `github-token`, or any future command that loads configuration) is invoked, the program SHALL load the TOML configuration file (from `--config` if supplied, otherwise the XDG default path), decode required key `overlay-path`, and decode optional keys `assets-path` and `github-token` when present. The program SHALL fail with an error-level log and exit status `1` if the file is missing, unreadable, or missing the required `overlay-path` key. When `github-token` is present and non-empty, the program SHALL fail config load unless the value is a `mndz1.` envelope (plaintext secrets on disk are not usable). Absence of optional keys SHALL NOT fail config load by itself. The program SHALL NOT accept legacy keys `mndz-overlay-path` or `mndz-overlay-assets-path` as substitutes for the new names. Paths that only render help (top-level `--help` / `-h`, bare invocation that only shows help, or `COMMAND --help` / `-h`) SHALL NOT load configuration.

#### Scenario: Missing config file

- **WHEN** the user runs a work subcommand and the resolved config file does not exist
- **THEN** the program logs an error containing the attempted path
- **AND** the program exits with status `1`

#### Scenario: Config missing overlay-path

- **WHEN** the config file exists but does not define `overlay-path`
- **THEN** the program logs an error describing the missing key
- **AND** the program exits with status `1`

#### Scenario: Optional assets path omitted

- **WHEN** the config file defines `overlay-path` but omits `assets-path`
- **THEN** config load succeeds and the assets path is treated as unset until a command requires it

#### Scenario: Optional github-token omitted

- **WHEN** the config file defines `overlay-path` but omits `github-token`
- **THEN** config load succeeds and the token is resolved from the environment if present

#### Scenario: Plaintext github-token fails load

- **WHEN** the config file defines `github-token` as a live PAT string
- **THEN** the program fails config load with an error-level log
- **AND** the program exits with status `1`

#### Scenario: Legacy mndz-overlay-path key is not accepted

- **WHEN** the config file defines `mndz-overlay-path` but does not define `overlay-path`
- **THEN** the program fails config load as missing the required `overlay-path` key
- **AND** the program exits with status `1`

## ADDED Requirements

### Requirement: github-token command skips overlay validation

The `github-token` command SHALL load configuration and SHALL NOT require overlay validation (`profiles/repo_name` equal to `mndz` or Gentoo layout entries). It SHALL require `assets-path` as specified by `github-token-command`. Commands that perform overlay work (`list`, `outdated`, `update`, `gencache`) still validate the overlay as specified by the overlay validation requirement.

#### Scenario: github-token without valid overlay

- **WHEN** the operator runs `github-token` with a valid config whose overlay-path would fail overlay validation
- **THEN** the command does not fail solely because of overlay validation
