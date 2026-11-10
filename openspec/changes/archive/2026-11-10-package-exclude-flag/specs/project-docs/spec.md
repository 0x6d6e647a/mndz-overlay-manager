# Spec Delta

## ADDED Requirements

### Requirement: README documents the exclude flag

`README.md` SHALL document `--exclude` on `outdated`, `update`, and `gencache` as a repeatable comma-separated list of package tokens, subtracted from the positional targets or from the whole inventory when none are given. Each of those sections SHALL include an example. The `update` section SHALL state that a non-empty removal logs one warning and that an empty selection is an error.

#### Scenario: README shows exclude on each selecting command

- **WHEN** an operator reads the `outdated`, `update`, and `gencache` sections of `README.md`
- **THEN** each section documents `--exclude` and shows an example invocation

#### Scenario: README states the warning and the empty-selection error

- **WHEN** an operator reads the `README.md` `update` section
- **THEN** the text states that a non-empty removal logs one warning
- **AND** the text states that an empty selection is an error

### Requirement: README documents an excluded provider

`README.md` SHALL state that `update` does not pull an excluded package back into the selection. It SHALL state that an excluded `dev-lang/bun-bin` stays an unselected ceiling provider, and that a dirty ensure-emerge atom is still checked when the materialize recipe will emerge it.

#### Scenario: README states an excluded provider stays out

- **WHEN** an operator reads the `README.md` `update` documentation
- **THEN** the text states that `--exclude dev-lang/bun-bin` does not add bun-bin back into the selection
- **AND** the text states that a dirty ensure-emerge atom is still checked when the recipe will emerge it
