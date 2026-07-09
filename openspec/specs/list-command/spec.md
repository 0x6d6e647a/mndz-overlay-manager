# list-command Specification

## Purpose

Define the `list` subcommand: printing package atoms for ebuilds in the overlay, empty-inventory handling, and the absence of subcommand-local options.

## Requirements

### Requirement: List subcommand prints package atoms

The CLI SHALL provide a `list` subcommand that, after successful config load, path resolution, overlay validation, and ebuild discovery, writes one package atom per line to standard output in the form `category/package-version` and exits with status `0`.

#### Scenario: List ebuilds in a populated overlay

- **WHEN** the user runs the program with the `list` subcommand against a valid overlay containing ebuilds
- **THEN** the program writes each discovered ebuild as a single line `category/package-version` to standard output
- **AND** the program exits with status `0`

#### Scenario: List uses ebuild atom formatting

- **WHEN** an ebuild is discovered at `dev-lang/haskell/haskell-9.4.5.ebuild`
- **THEN** the corresponding output line is exactly `dev-lang/haskell-9.4.5`

### Requirement: Empty inventory is an error

When discovery finds zero ebuilds in a validated overlay, the program SHALL log an error-level message and exit with status `1` without writing package atoms to standard output.

#### Scenario: Valid overlay with no ebuilds

- **WHEN** the user runs `list` against a valid overlay that contains no ebuilds
- **THEN** the program logs an error describing that no ebuilds were found
- **AND** the program exits with status `1`

### Requirement: List has no subcommand-specific options

The `list` subcommand SHALL accept no arguments or subcommand-local flags. Filtering and formatting remain out of scope; users may pipe stdout to other tools.

#### Scenario: List invoked with only global options

- **WHEN** the user runs `list` with only top-level flags such as `--config` or `--overlay-path`
- **THEN** the program treats `list` as a zero-argument subcommand and proceeds with path resolution and discovery
