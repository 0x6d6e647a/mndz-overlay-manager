## MODIFIED Requirements

### Requirement: Exclude values are whitespace-separated tokens

Each `--exclude` value SHALL be split on whitespace into package tokens. An empty or whitespace-only value SHALL fail option parsing with exit status `1` before configuration is loaded. Commas SHALL NOT act as separators. Repeating `--exclude` SHALL union the tokens into one set. A comma inside a positional `PACKAGE` argument SHALL remain part of that single argument.

#### Scenario: Whitespace-separated list with surrounding spaces

- **WHEN** the user runs `outdated --exclude "  dev-util/codex  dev-util/crush  "`
- **THEN** the exclude set contains `dev-util/codex` and `dev-util/crush`

#### Scenario: Repeated flags union

- **WHEN** the user runs `gencache --exclude dev-util/codex --exclude dev-util/crush`
- **THEN** the exclude set contains both packages

#### Scenario: Whitespace-only value fails before config load

- **WHEN** the user runs `update --exclude "   "`
- **THEN** option parsing fails with exit status `1` before configuration is loaded

#### Scenario: Commas are not separators

- **WHEN** the user runs `update --exclude dev-util/codex,dev-util/crush`
- **THEN** the value is not interpreted as two packages
- **AND** the command fails without performing package work

#### Scenario: Positional comma is one argument

- **WHEN** the user runs `outdated dev-util/codex,dev-util/crush`
- **THEN** the program treats that word as one positional target

### Requirement: Selection is the base minus exclusions

With no positional package arguments, the base SHALL be every discovered package. With positional arguments, the base SHALL be those resolved targets in that command's existing explicit-target order. The selection SHALL be the base with resolved exclude keys removed, preserving the order of the keys that remain. Duplicate tokens SHALL collapse to one key.

#### Scenario: Untargeted exclude drops one package

- **WHEN** the user runs `outdated --exclude dev-util/codex` and the inventory contains other packages
- **THEN** every discovered package except `dev-util/codex` is selected
- **AND** the remaining packages keep inventory order

#### Scenario: Positional list minus one target

- **WHEN** the user runs `update dev-util/crush dev-util/dolt --exclude dev-util/dolt`
- **THEN** the selection is `dev-util/crush` in that positional order

#### Scenario: Duplicate tokens collapse

- **WHEN** the user runs `gencache --exclude "dev-util/codex dev-util/codex"`
- **THEN** `dev-util/codex` is excluded once

### Requirement: Removal warning names canonical keys

When the selection is non-empty and at least one base package was removed, the program SHALL log one warning before package work, visible at the default log level. One removed key SHALL use `excluding <category/package>`. More than one SHALL use `excluding <N> packages: ` plus those keys in inventory order separated by `, `. A resolved exclude key that was not in the base SHALL NOT appear.

#### Scenario: One removed package

- **WHEN** the user runs `update --exclude dev-util/codex` and other packages remain selected
- **THEN** the program logs the warning `excluding dev-util/codex` before update work

#### Scenario: Several removed packages

- **WHEN** the user runs `gencache --exclude "dev-util/crush dev-util/codex"` and both are in the inventory and other packages remain
- **THEN** the program logs `excluding 2 packages: ` followed by those two keys in inventory order

#### Scenario: Unused exclude adds no warning name

- **WHEN** the user runs `outdated dev-util/crush --exclude dev-util/codex` and both packages exist
- **THEN** the warning does not name `dev-util/codex`
