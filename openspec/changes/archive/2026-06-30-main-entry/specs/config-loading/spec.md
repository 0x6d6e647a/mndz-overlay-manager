## ADDED Requirements

### Requirement: TOML config is loaded and validated for non-help invocations
When a subcommand other than top-level help is invoked, the program SHALL locate the config file (respecting `XDG_CONFIG_HOME` with fallback to `~/.config/mndz/overlay-manager.toml`), decode it with `toml-parser`, and validate that:
- the file exists,
- the `mndz-overlay-path` key is present,
- the path exists on disk and is a directory,
- the directory contains `profiles/`, `metadata/`, `profiles/repo_name`, and `metadata/layout.conf`,
- the content of `profiles/repo_name` is exactly the string `mndz`.

All validation failures SHALL produce an error-level log message naming the exact problem and the path attempted, then exit with status 1.

#### Scenario: Missing config file produces precise error
- **WHEN** the config file does not exist at the resolved path
- **THEN** the program logs an error message containing the attempted path and exits with status 1

#### Scenario: Invalid overlay layout produces precise error
- **WHEN** `mndz-overlay-path` points to a directory missing any of the four required entries or the `repo_name` file does not contain `mndz`
- **THEN** the program logs an error message describing the exact missing piece or mismatch and exits with status 1

#### Scenario: `--config` override is honored
- **WHEN** the user supplies `--config /tmp/test.toml`
- **THEN** the program attempts to load `/tmp/test.toml` instead of the default location and reports errors against that path if validation fails
