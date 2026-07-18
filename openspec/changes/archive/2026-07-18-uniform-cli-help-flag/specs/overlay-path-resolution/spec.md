## MODIFIED Requirements

### Requirement: Config is loaded for every non-help invocation

When a work subcommand (`list`, `outdated`, `update`, or any future command that performs overlay work) is invoked, the program SHALL load the TOML configuration file (from `--config` if supplied, otherwise the XDG default path), decode required key `overlay-path`, and decode optional keys `assets-path` and `github-token` when present. The program SHALL fail with an error-level log and exit status `1` if the file is missing, unreadable, or missing the required `overlay-path` key. Absence of optional keys SHALL NOT fail config load by itself. The program SHALL NOT accept legacy keys `mndz-overlay-path` or `mndz-overlay-assets-path` as substitutes for the new names. Paths that only render help (top-level `--help` / `-h`, bare invocation that only shows help, or `COMMAND --help` / `-h`) SHALL NOT load configuration.

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

#### Scenario: Legacy mndz-overlay-path key is not accepted

- **WHEN** the config file defines `mndz-overlay-path` but does not define `overlay-path`
- **THEN** the program fails config load as missing the required `overlay-path` key
- **AND** the program exits with status `1`

### Requirement: Overlay path CLI override after config load

The CLI SHALL provide a top-level `--overlay-path` option. For work subcommands the program SHALL always load configuration first, then set the effective overlay path to the `--overlay-path` value when present, otherwise to `overlay-path` from the config.

#### Scenario: Override wins over config path

- **WHEN** the user supplies `--overlay-path /tmp/other-overlay` and a config that points at a different path
- **THEN** the program uses `/tmp/other-overlay` as the effective overlay path for validation and subsequent work

#### Scenario: Config path used when override absent

- **WHEN** the user runs a work subcommand without `--overlay-path`
- **THEN** the program uses `overlay-path` from the loaded config as the effective overlay path

### Requirement: Overlay validation gates non-help commands

After resolving the effective overlay path, the program SHALL run overlay validation (existence of required Gentoo layout entries and `repo_name` equal to `mndz`). Validation failure SHALL produce an error-level log and exit status `1`. Help-only invocations (top-level `--help` / `-h`, bare invocation that only shows help, or `COMMAND --help` / `-h`) SHALL NOT require config load or overlay validation.

#### Scenario: Invalid overlay after path resolution

- **WHEN** the effective overlay path fails validation
- **THEN** the program logs an error describing the validation failure
- **AND** the program exits with status `1`

#### Scenario: Help skips config and validation

- **WHEN** the user runs `--help`, `-h`, bare invocation that only shows help, or `list --help` / `outdated --help` / `update --help`
- **THEN** the program shows help without requiring a valid config file or overlay path

### Requirement: Assets path available from config when set

When `assets-path` is present in the loaded config, the program SHALL expose that path to update logic that publishes assets. Validation that the path exists and is a git work tree SHALL occur when a command determines that assets publish is required, not necessarily at initial config decode for every work subcommand.

#### Scenario: Assets path carried in config value

- **WHEN** config sets `assets-path` to `/home/user/mndz-overlay-assets`
- **THEN** update logic that needs assets can read that path from the loaded configuration
