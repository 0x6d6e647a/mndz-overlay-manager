## ADDED Requirements

### Requirement: README documents outdated package targets

When documenting the `outdated` command, `README.md` SHALL state that `outdated` accepts zero or more package arguments in the same form as `update` (`category/package` or unambiguous package name), that omitting arguments checks all discovered packages, and SHALL include at least one example with a package target.

#### Scenario: README shows filtered outdated example

- **WHEN** an operator reads the README `outdated` section after this change
- **THEN** the section describes optional package targets and shows an example such as `outdated category/package` or `outdated package`
