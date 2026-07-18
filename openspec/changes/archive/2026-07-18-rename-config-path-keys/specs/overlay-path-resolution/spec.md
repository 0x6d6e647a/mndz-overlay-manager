## MODIFIED Requirements

### Requirement: Config is loaded for every non-help invocation

When a subcommand other than top-level help is invoked, the program SHALL load the TOML configuration file (from `--config` if supplied, otherwise the XDG default path), decode required key `overlay-path`, and decode optional keys `assets-path` and `github-token` when present. The program SHALL fail with an error-level log and exit status `1` if the file is missing, unreadable, or missing the required `overlay-path` key. Absence of optional keys SHALL NOT fail config load by itself. The program SHALL NOT accept legacy keys `mndz-overlay-path` or `mndz-overlay-assets-path` as substitutes for the new names.

#### Scenario: Missing config file

- **WHEN** the user runs a non-help command and the resolved config file does not exist
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

The CLI SHALL provide a top-level `--overlay-path` option. For non-help commands the program SHALL always load configuration first, then set the effective overlay path to the `--overlay-path` value when present, otherwise to `overlay-path` from the config.

#### Scenario: Override wins over config path

- **WHEN** the user supplies `--overlay-path /tmp/other-overlay` and a config that points at a different path
- **THEN** the program uses `/tmp/other-overlay` as the effective overlay path for validation and subsequent work

#### Scenario: Config path used when override absent

- **WHEN** the user runs a non-help command without `--overlay-path`
- **THEN** the program uses `overlay-path` from the loaded config as the effective overlay path

### Requirement: Assets path available from config when set

When `assets-path` is present in the loaded config, the program SHALL expose that path to update logic that publishes assets. Validation that the path exists and is a git work tree SHALL occur when a command determines that assets publish is required, not necessarily at initial config decode for every non-help command.

#### Scenario: Assets path carried in config value

- **WHEN** config sets `assets-path` to `/home/user/mndz-overlay-assets`
- **THEN** update logic that needs assets can read that path from the loaded configuration

### Requirement: Assets path validation when required

When `update` will attempt assets publish for at least one selected package, the program SHALL verify that `assets-path` is set, names an existing directory that is inside a git work tree, and fail the spine with exit status `1` if validation fails. User-visible error text about the missing or invalid path SHALL name the config key `assets-path`.

#### Scenario: Missing assets path when Go update selected

- **WHEN** `update` selects a `GoVendorAndAssets` package that will apply and assets path is unset
- **THEN** the program logs an error and exits with status `1` before package mutation

#### Scenario: Assets path not a git worktree

- **WHEN** `assets-path` points at a directory that is not a git work tree and assets publish is required
- **THEN** the program logs an error and exits with status `1` before package mutation
