# logging-bootstrap Specification

## Purpose

Severity filtering from CLI verbosity, custom severity color palette, and `NO_COLOR` / `--no-color` respect for co-log stderr logging.

## Requirements

### Requirement: Verbosity filters log severity

After CLI options are parsed, the program SHALL configure the co-log logger so that only messages at or above the selected verbosity are emitted. Mapping SHALL be:

- `error` → Error and above
- `warn` → Warning and above (default)
- `info` → Info and above
- `debug` → Debug and above

#### Scenario: Default hides info and debug

- **WHEN** the user runs a command without verbosity flags and an info-level message is logged
- **THEN** the info message is not written to stderr

#### Scenario: Debug level shows debug messages

- **WHEN** the user runs with `--log-level debug` and a debug-level message is logged
- **THEN** the debug message is written to stderr

### Requirement: Verbose flag increases level from warn

The `-v` / `--verbose` flag SHALL be usable without requiring `--log-level`. With no `--log-level` and no `-v`, the level SHALL be `warn`. Each additional `-v` SHALL increase verbosity one step toward `debug` (`warn` → `info` → `debug`), capped at `debug`. When `--log-level` is provided, that explicit level SHALL take precedence over `-v` counts.

#### Scenario: Single -v enables info

- **WHEN** the user passes `-v` and does not pass `--log-level`
- **THEN** the effective log level is `info`

#### Scenario: Double -v enables debug

- **WHEN** the user passes `-vv` and does not pass `--log-level`
- **THEN** the effective log level is `debug`

#### Scenario: Explicit log-level overrides -v

- **WHEN** the user passes `--log-level error -vv`
- **THEN** the effective log level is `error`

### Requirement: Severity color palette

When color is enabled, severity tags on log lines SHALL use:

- Info: green
- Warning: yellow
- Error: red
- Debug: magenta

#### Scenario: Error tag is red when color enabled

- **WHEN** color is enabled and an error is logged
- **THEN** the severity tag portion of the line uses red ANSI coloring

### Requirement: Color can be disabled

The program SHALL disable ANSI coloring for log severity tags when either the global `--no-color` flag is set or the environment variable `NO_COLOR` is set to a non-empty value. When color is disabled, severity tags SHALL still appear as plain text labels without color escape sequences.

#### Scenario: NO_COLOR disables log color

- **WHEN** `NO_COLOR` is set to a non-empty value and an error is logged
- **THEN** the log line does not contain ANSI color escape sequences for the severity tag

#### Scenario: --no-color disables log color

- **WHEN** the user passes `--no-color` and a warning is logged
- **THEN** the log line does not contain ANSI color escape sequences for the severity tag

### Requirement: Logger remains stderr-based

Log messages SHALL continue to be written to standard error (when not suppressed by severity filtering), not to standard output.

#### Scenario: Errors go to stderr

- **WHEN** a fatal config error is logged
- **THEN** the message appears on stderr
