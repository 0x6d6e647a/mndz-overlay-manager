## ADDED Requirements

### Requirement: Config is loaded for every non-help invocation

When a subcommand other than top-level help is invoked, the program SHALL load the TOML configuration file (from `--config` if supplied, otherwise the XDG default path), decode `mndz-overlay-path`, and fail with an error-level log and exit status `1` if the file is missing, unreadable, or missing the required key.

#### Scenario: Missing config file

- **WHEN** the user runs a non-help command and the resolved config file does not exist
- **THEN** the program logs an error containing the attempted path
- **AND** the program exits with status `1`

#### Scenario: Config missing mndz-overlay-path

- **WHEN** the config file exists but does not define `mndz-overlay-path`
- **THEN** the program logs an error describing the missing key
- **AND** the program exits with status `1`

### Requirement: Overlay path CLI override after config load

The CLI SHALL provide a top-level `--overlay-path` option. For non-help commands the program SHALL always load configuration first, then set the effective overlay path to the `--overlay-path` value when present, otherwise to `mndz-overlay-path` from the config.

#### Scenario: Override wins over config path

- **WHEN** the user supplies `--overlay-path /tmp/other-overlay` and a config that points at a different path
- **THEN** the program uses `/tmp/other-overlay` as the effective overlay path for validation and subsequent work

#### Scenario: Config path used when override absent

- **WHEN** the user runs a non-help command without `--overlay-path`
- **THEN** the program uses `mndz-overlay-path` from the loaded config as the effective overlay path

### Requirement: Overlay validation gates non-help commands

After resolving the effective overlay path, the program SHALL run overlay validation (existence of required Gentoo layout entries and `repo_name` equal to `mndz`). Validation failure SHALL produce an error-level log and exit status `1`. Help invocations SHALL NOT require config load or overlay validation.

#### Scenario: Invalid overlay after path resolution

- **WHEN** the effective overlay path fails validation
- **THEN** the program logs an error describing the validation failure
- **AND** the program exits with status `1`

#### Scenario: Help skips config and validation

- **WHEN** the user runs `help` or `--help`
- **THEN** the program shows help without requiring a valid config file or overlay path
