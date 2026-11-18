## MODIFIED Requirements

### Requirement: README documents the exclude flag

`README.md` SHALL document `--exclude` on `outdated`, `update`, `gencache`, and `smoke` as a repeatable whitespace-separated list of package tokens, subtracted from the positional targets or from the whole inventory when none are given. It SHALL explain shell quoting for multiple tokens and show a quoted multi-token example. Each of those sections SHALL include an example. The `update` section SHALL state that a non-empty removal logs one warning and that an empty selection is an error.

#### Scenario: README shows exclude on each selecting command

- **WHEN** an operator reads the `outdated`, `update`, `gencache`, and `smoke` sections of `README.md`
- **THEN** each section documents `--exclude` and shows an example invocation
- **AND** the README shows a quoted whitespace-separated list

#### Scenario: README states the warning and the empty-selection error

- **WHEN** an operator reads the `README.md` `update` section
- **THEN** the text states that a non-empty removal logs one warning
- **AND** the text states that an empty selection is an error
