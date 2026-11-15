# Spec Delta

## MODIFIED Requirements

### Requirement: Outdated refresh flag

The `outdated` subcommand SHALL accept a `--refresh` flag that forces live upstream check or plan work for all selected packages, ignoring existing cache entries for reads, and SHALL write fresh eligible entries when the cache is enabled. `--refresh` SHALL also force a managed Gentoo tree sync before planning, regardless of the tree's age, as specified by `gentoo-tree`.

#### Scenario: Refresh ignores existing entries

- **WHEN** the user runs `outdated --refresh` while valid cache entries exist for selected packages
- **THEN** the program performs live check or plan work for those packages rather than using the existing entries for reads

#### Scenario: Outdated refresh syncs the tree

- **WHEN** the user runs `outdated --refresh` and the managed tree was synced ten minutes ago
- **THEN** the program syncs the tree before planning
