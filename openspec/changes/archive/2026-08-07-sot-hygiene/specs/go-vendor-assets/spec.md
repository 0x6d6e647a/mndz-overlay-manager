## MODIFIED Requirements

### Requirement: DepsAndAssets Go technique

The program SHALL support Go packages under the update technique `DepsAndAssets` with ecosystem `Go` and an optional go.mod subdirectory relative to the upstream repository root (unset means repository root). Apply logic SHALL use this subdirectory when running Go module download after clone. There SHALL NOT be a separate legacy Go-only technique constructor outside `DepsAndAssets` with ecosystem `Go`. Package membership in the hardcoded map is defined by `update-apply`, not by this capability.

#### Scenario: Root go.mod package

- **WHEN** policy for `dev-util/beads` uses `DepsAndAssets` with ecosystem `Go` and no subdirectory
- **THEN** vendor construction runs in the cloned repository root where `go.mod` is present

#### Scenario: Subdirectory go.mod package

- **WHEN** policy for `dev-db/dolt` uses `DepsAndAssets` with ecosystem `Go` and subdirectory `go`
- **THEN** vendor construction runs in the `go/` directory of the clone

## REMOVED Requirements

### Requirement: Hardcoded Go packages use DepsAndAssets Go

**Reason**: Duplicates the canonical package policy map in `update-apply` and risked drift (partial lists elsewhere already omitted packages).

**Migration**: Resolve Go package techniques and sources from `update-apply` “Hardcoded policy covers known overlay packages”. Use remaining Go-only materialize requirements in this capability for vendor/SRC_URI/BDEPEND/reuse behavior.
