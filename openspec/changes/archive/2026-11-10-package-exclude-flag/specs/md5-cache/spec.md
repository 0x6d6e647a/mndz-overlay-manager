# Spec Delta

## MODIFIED Requirements

### Requirement: gencache package targets

`gencache` SHALL accept zero or more package arguments in the same form as `update` (`category/package` or unambiguous package name) and the subcommand-local `--exclude` flag specified by `package-exclude`. The packages whose cache is generated SHALL be that selection. With no positional arguments and no `--exclude`, every package that has at least one discovered ebuild SHALL be selected. Explicit targets that cannot be resolved SHALL hard-fail the command (or soft-skip only if consistent with existing update target policy—prefer hard-fail for unknown names). Selected packages are the only packages whose cache is generated in that run.

#### Scenario: No args selects all packages

- **WHEN** the user runs `gencache` with no package arguments
- **THEN** every inventoried package is selected for cache generation

#### Scenario: Explicit package only

- **WHEN** the user runs `gencache dev-util/crush`
- **THEN** only `dev-util/crush` is passed to egencache update (not unrelated packages)

#### Scenario: Exclude removes a package from a full-tree run

- **WHEN** the user runs `gencache --exclude dev-util/crush` and other packages have ebuilds
- **THEN** cache generation includes those other packages
- **AND** it does not include `dev-util/crush`

#### Scenario: Force still skips an excluded package

- **WHEN** the user runs `gencache --force --exclude dev-util/crush`
- **THEN** `dev-util/crush` is not regenerated
- **AND** the remaining selected packages are regenerated
