## MODIFIED Requirements

### Requirement: Config is loaded for every non-help invocation

When a subcommand other than top-level help is invoked, the program SHALL load the TOML configuration file (from `--config` if supplied, otherwise the XDG default path), decode required key `mndz-overlay-path`, and decode optional keys `mndz-overlay-assets-path` and `github-token` when present. The program SHALL fail with an error-level log and exit status `1` if the file is missing, unreadable, or missing the required `mndz-overlay-path` key. Absence of optional keys SHALL NOT fail config load by itself.

#### Scenario: Missing config file

- **WHEN** the user runs a non-help command and the resolved config file does not exist
- **THEN** the program logs an error containing the attempted path
- **AND** the program exits with status `1`

#### Scenario: Config missing mndz-overlay-path

- **WHEN** the config file exists but does not define `mndz-overlay-path`
- **THEN** the program logs an error describing the missing key
- **AND** the program exits with status `1`

#### Scenario: Optional assets path omitted

- **WHEN** the config file defines `mndz-overlay-path` but omits `mndz-overlay-assets-path`
- **THEN** config load succeeds and the assets path is treated as unset until a command requires it

#### Scenario: Optional github-token omitted

- **WHEN** the config file defines `mndz-overlay-path` but omits `github-token`
- **THEN** config load succeeds and the token is resolved from the environment if present

## ADDED Requirements

### Requirement: Assets path available from config when set

When `mndz-overlay-assets-path` is present in the loaded config, the program SHALL expose that path to update logic that publishes assets. Validation that the path exists and is a git work tree SHALL occur when a command determines that assets publish is required, not necessarily at initial config decode for every non-help command.

#### Scenario: Assets path carried in config value

- **WHEN** config sets `mndz-overlay-assets-path` to `/home/user/mndz-overlay-assets`
- **THEN** update logic that needs assets can read that path from the loaded configuration

### Requirement: Assets path validation when required

When `update` will attempt assets publish for at least one selected package, the program SHALL verify that `mndz-overlay-assets-path` is set, names an existing directory that is inside a git work tree, and fail the spine with exit status `1` if validation fails.

#### Scenario: Missing assets path when Go update selected

- **WHEN** `update` selects a `GoVendorAndAssets` package that will apply and assets path is unset
- **THEN** the program logs an error and exits with status `1` before package mutation

#### Scenario: Assets path not a git worktree

- **WHEN** `mndz-overlay-assets-path` points at a directory that is not a git work tree and assets publish is required
- **THEN** the program logs an error and exits with status `1` before package mutation
