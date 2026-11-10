# Spec Delta

## Purpose

Define the shared `--exclude` flag that removes packages from the `outdated`, `update`, and `gencache` selection.

## ADDED Requirements

### Requirement: Exclude flag is subcommand-local

`outdated`, `update`, and `gencache` SHALL each accept a repeatable long option `--exclude`. `list`, `eclean`, and `github-token` SHALL reject `--exclude`. The program SHALL NOT read exclusions from its configuration file, and SHALL NOT accept a short form of this option.

#### Scenario: Outdated accepts the long option

- **WHEN** the user runs `outdated --exclude dev-util/codex`
- **THEN** the program accepts `--exclude` as a subcommand option of `outdated`

#### Scenario: Repeated flags are one option

- **WHEN** the user runs `update --exclude dev-util/codex --exclude dev-util/crush`
- **THEN** the program accepts both `--exclude` options on `update`

#### Scenario: List rejects the option

- **WHEN** the user runs `list --exclude dev-util/codex`
- **THEN** option parsing fails with exit status `1` before configuration is loaded

#### Scenario: Flag before the subcommand is rejected

- **WHEN** the user runs `--exclude dev-util/codex outdated`
- **THEN** option parsing fails with exit status `1` before configuration is loaded

### Requirement: Exclude values are comma-separated tokens

Each `--exclude` value SHALL be split on commas into package tokens, and ASCII whitespace around each token SHALL be trimmed. An empty token SHALL fail option parsing with exit status `1` before configuration is loaded. Repeating `--exclude` SHALL union the tokens into one set. A comma inside a positional `PACKAGE` argument SHALL remain part of that single argument.

#### Scenario: Comma list and surrounding spaces

- **WHEN** the user runs `outdated --exclude "dev-util/codex, dev-util/crush"`
- **THEN** the exclude set contains `dev-util/codex` and `dev-util/crush`

#### Scenario: Repeated flags union

- **WHEN** the user runs `gencache --exclude dev-util/codex --exclude dev-util/crush`
- **THEN** the exclude set contains both packages

#### Scenario: Empty segment fails before config load

- **WHEN** the user runs `update --exclude "dev-util/codex,"`
- **THEN** option parsing fails with exit status `1` before configuration is loaded

#### Scenario: Positional comma is one argument

- **WHEN** the user runs `outdated dev-util/codex,dev-util/crush`
- **THEN** the program treats that word as one positional target

### Requirement: Exclude tokens resolve like package targets

Each exclude token SHALL be a `category/package` key or a bare package name, resolved with the same rules as a positional package target. An unknown token or an ambiguous bare name SHALL hard-fail with those same errors and exit status `1` before package work, and every such token SHALL be reported. A PV, a category, or a glob SHALL NOT match a version or more than one package. A resolved key that is not in the base SHALL be ignored.

#### Scenario: Unknown exclude hard-fails

- **WHEN** the user runs `outdated --exclude missing/pkg` and that key is not in the inventory
- **THEN** the program logs the unknown-target error and exits with status `1` without running package checks

#### Scenario: Ambiguous bare exclude hard-fails

- **WHEN** the user runs `update --exclude foo` and two categories both contain package name `foo`
- **THEN** the program logs the ambiguity error and exits with status `1` without planning

#### Scenario: Version token is unknown

- **WHEN** the user runs `gencache --exclude crush-1.2.3` and no package key is exactly `crush-1.2.3`
- **THEN** the program logs the unknown-target error and exits with status `1` without generating cache

#### Scenario: Exclude outside the base is ignored

- **WHEN** the user runs `outdated dev-util/crush --exclude dev-util/codex` and both packages exist
- **THEN** the program checks `dev-util/crush` and does not fail because `dev-util/codex` was excluded

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

- **WHEN** the user runs `gencache --exclude dev-util/codex,dev-util/codex`
- **THEN** `dev-util/codex` is excluded once

### Requirement: Empty selection after exclusion is an error

When exclusion removes every package in the base, the program SHALL log one error, `exclusions removed every selected package: ` followed by the removed `category/package` keys in inventory order separated by `, `, and SHALL exit with status `1` before network, planning, mutation, or md5-cache generation. It SHALL NOT also log the exclusion warning.

#### Scenario: Excluding the only target

- **WHEN** the user runs `update dev-util/crush --exclude dev-util/crush`
- **THEN** the program logs `exclusions removed every selected package: dev-util/crush`
- **AND** exits with status `1` without planning or mutating

#### Scenario: Excluding the whole inventory

- **WHEN** the user runs `outdated --exclude` with a token list that names every discovered package
- **THEN** the program exits with status `1` before package checks
- **AND** the error names those packages in inventory order

### Requirement: Removal warning names canonical keys

When the selection is non-empty and at least one base package was removed, the program SHALL log one warning before package work, visible at the default log level. One removed key SHALL use `excluding <category/package>`. More than one SHALL use `excluding <N> packages: ` plus those keys in inventory order separated by `, `. A resolved exclude key that was not in the base SHALL NOT appear.

#### Scenario: One removed package

- **WHEN** the user runs `update --exclude dev-util/codex` and other packages remain selected
- **THEN** the program logs the warning `excluding dev-util/codex` before update work

#### Scenario: Several removed packages

- **WHEN** the user runs `gencache --exclude dev-util/crush,dev-util/codex` and both are in the inventory and other packages remain
- **THEN** the program logs `excluding 2 packages: ` followed by those two keys in inventory order

#### Scenario: Unused exclude adds no warning name

- **WHEN** the user runs `outdated dev-util/crush --exclude dev-util/codex` and both packages exist
- **THEN** the warning does not name `dev-util/codex`

### Requirement: Excluded packages are not pulled back

Checks, update planning, mutation, and md5-cache generation SHALL run only for the selection. The program SHALL NOT add an excluded package back because another selected package depends on it. `--refresh` SHALL force live work only for the remaining `outdated` or `update` selection. `gencache --force` SHALL regenerate cache only for the remaining selection.

#### Scenario: Excluded package is not checked

- **WHEN** the user runs `outdated --exclude dev-util/codex`
- **THEN** `dev-util/codex` produces no stdout line and no per-package soft warning

#### Scenario: Excluded provider stays out

- **WHEN** the user runs `update --exclude dev-lang/bun-bin` and a selected DepsAndAssets Bun consumer remains
- **THEN** the program does not mutate `dev-lang/bun-bin`

#### Scenario: Force does not regenerate an excluded package

- **WHEN** the user runs `gencache --force --exclude dev-util/crush`
- **THEN** cache generation does not include `dev-util/crush`
