## ADDED Requirements

### Requirement: Outdated uses check cache

The `outdated` command SHALL load and consult the shared check cache for selected packages when the cache is enabled and `--refresh` was not passed. On a valid hit, the command SHALL derive check outcomes from the cached remote PV or runtime-lane plan (with content-fix still computed from disk) without repeating upstream latest fetch or deps plan network work for that package. After successful live checks, the command SHALL store eligible entries when the cache is enabled. The command SHALL emit the check-cache hit/fetch info summary as specified by `check-cache`.

#### Scenario: Second outdated within TTL hits cache

- **WHEN** the user runs `outdated` successfully and then runs `outdated` again within the effective TTL without `--refresh` and without local fingerprint changes
- **THEN** configured packages with stored entries may complete without repeating their upstream check network work

#### Scenario: Outdated stores after live check

- **WHEN** the user runs `outdated --refresh` (or a cold cache) and a package check succeeds
- **THEN** an eligible cache entry for that package is written when the cache is enabled

### Requirement: Outdated refresh flag

The `outdated` subcommand SHALL accept a `--refresh` flag that forces live upstream check or plan work for all selected packages, ignoring existing cache entries for reads, and SHALL write fresh eligible entries when the cache is enabled.

#### Scenario: Refresh ignores existing entries

- **WHEN** the user runs `outdated --refresh` while valid cache entries exist for selected packages
- **THEN** the program performs live check or plan work for those packages rather than using the existing entries for reads

## MODIFIED Requirements

### Requirement: Outdated package targets

The `outdated` subcommand SHALL accept zero or more package targets and MAY accept the subcommand-local flag `--refresh` (see outdated refresh requirement). It SHALL NOT accept other subcommand-local flags beyond `--refresh`. Each target SHALL be either a full key `category/package` or a package name `package` that is unambiguous among discovered packages. With zero targets, the program SHALL check every package key present in the discovered inventory. With one or more targets, the program SHALL resolve tokens with the same rules as `update` and `gencache` (shared target resolution): unknown package tokens and ambiguous bare package names SHALL be hard failures that abort the command before per-package checks (exit status `1`). After successful resolution, the program SHALL run outdated checks only for the selected package keys; packages not in the selection SHALL produce neither stdout outdated lines nor soft-warning outcomes for this run. Version or PV values SHALL NOT be accepted as CLI arguments. Global options such as `--config`, `--overlay-path`, `--jobs`, and log verbosity still apply.

#### Scenario: Zero targets checks full inventory

- **WHEN** the user runs `outdated` with only top-level flags such as `--config` or `--overlay-path` and no package arguments
- **THEN** the program checks every discovered package

#### Scenario: Category package target

- **WHEN** the user runs `outdated dev-util/crush` against an inventory that contains that package
- **THEN** the program checks only `dev-util/crush` and does not emit outdated lines or soft warnings for other packages solely because they were not selected

#### Scenario: Bare package name

- **WHEN** the user runs `outdated crush` and exactly one discovered package has package name `crush`
- **THEN** the program checks that package key

#### Scenario: Ambiguous bare name hard-fails

- **WHEN** the user runs `outdated foo` and two categories both contain package name `foo`
- **THEN** the program logs an error describing the ambiguity and exits with status `1` without running the check loop

#### Scenario: Unknown package hard-fails

- **WHEN** the user runs `outdated missing/pkg` and that key is not in the inventory
- **THEN** the program logs an error and exits with status `1` without running the check loop

#### Scenario: Refresh with targets

- **WHEN** the user runs `outdated --refresh dev-util/crush`
- **THEN** the program resolves the target and forces live check work for that package only
