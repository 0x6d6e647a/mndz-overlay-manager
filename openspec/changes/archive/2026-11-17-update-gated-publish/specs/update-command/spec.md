# Spec Delta

## MODIFIED Requirements

### Requirement: Update stdout for successful bumps

For each non-`DepsAndAssets` package successfully updated, committed, and pushed, the program SHALL write exactly one line to standard output of the form `category/package LOCAL -> REMOTE`, using the same version pretty-rendering conventions as `outdated` (PV form, no leading `v`). For `DepsAndAssets` packages, stdout SHALL follow the runtime-lane update stdout requirement (possibly multiple labeled lines). Packages that are soft-skipped, hard-failed, or held SHALL NOT produce a success stdout line.

#### Scenario: GitMv single line

- **WHEN** a GitMv package updates from `1.0` to `1.1`
- **THEN** stdout contains exactly one success line without a runtime-lane label

#### Scenario: Push failure prints no success line

- **WHEN** a GitMv package commits `1.1` and the overlay push fails
- **THEN** stdout contains no success line for that package

## ADDED Requirements

### Requirement: Update compile cache flag

`update` SHALL accept the subcommand-local flag `--no-compile-cache`. With it, the gated smoke runs of that command SHALL run as `smoke --no-compile-cache` runs do. Without it, gated runs SHALL use the compile cache as `smoke` does.

#### Scenario: Opt-out

- **WHEN** the operator runs `update --no-compile-cache hk`
- **THEN** the gated run containers have no `mndz-smoke-compile-cache` mount

#### Scenario: Flag with targets

- **WHEN** the operator runs `update --no-compile-cache --exclude dev-util/mise`
- **THEN** option parsing succeeds
