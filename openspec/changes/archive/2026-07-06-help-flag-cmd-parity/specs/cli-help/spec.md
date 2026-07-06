## ADDED Requirements

### Requirement: Help flag renders usage text

The CLI SHALL render its top-level usage/help text when invoked with the `--help` flag (or its `-h` short form), writing to standard output and exiting with status `0`.

#### Scenario: User requests help via flag

- **WHEN** the user runs the program with `--help`
- **THEN** the program writes the top-level usage text to standard output
- **AND** the program exits with status `0`

### Requirement: Help subcommand has parity with help flag

The CLI SHALL provide a `help` subcommand that produces output and exit behavior identical to the `--help` flag. The `help` subcommand SHALL accept no arguments.

#### Scenario: User requests help via subcommand

- **WHEN** the user runs the program with the `help` subcommand
- **THEN** the program writes the top-level usage text to standard output
- **AND** the program exits with status `0`

#### Scenario: Help subcommand output matches help flag output

- **WHEN** the output of the `help` subcommand is compared to the output of the `--help` flag
- **THEN** the two outputs are identical
- **AND** both exit with status `0`
