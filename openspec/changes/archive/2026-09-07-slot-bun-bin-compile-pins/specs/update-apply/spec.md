## MODIFIED Requirements

### Requirement: GitMvAndManifest leaves other versions

`GitMvAndManifest` apply behavior for non-selected ebuild versions in the package directory SHALL leave other non-selected versions in place. Exact-set pruning applies only to `DepsAndAssets` runtime-lane apply, as extended by `overlay-atom-closure` reverse-dep keep. GitMv rename of the newest ebuild SHALL honor the rename-away guard specified by `overlay-atom-closure`, except that `dev-lang/bun-bin` compile-pin keep SHALL add latest and rewrite the pin SLOT as specified below rather than hard-failing.

#### Scenario: Binary update does not delete siblings

- **WHEN** a `GitMvAndManifest` package directory has two ebuild versions and newest is renamed to a new remote PV
- **THEN** the non-selected older ebuild is left in place by that technique

#### Scenario: Rename-away of a required exact pin fails

- **WHEN** GitMv would rename the only matching provider PV away from an exact pin still required by a remaining consumer ebuild, and the provider is not bun-bin compile-pin keep
- **THEN** the GitMv unit hard-fails without renaming

#### Scenario: bun-bin compile pin does not hard-fail rename-away

- **WHEN** bun-bin GitMv would move newest `1.3.14` to `1.4.2` and a remaining opencode ebuild contains `=dev-lang/bun-bin-1.3.14`
- **THEN** the unit does not hard-fail solely for that pin
- **AND** apply adds latest and keeps `1.3.14` as specified for bun-bin GitMv add-latest

## ADDED Requirements

### Requirement: bun-bin GitMv adds latest when a compile pin must stay

When `GitMvAndManifest` for `dev-lang/bun-bin` would otherwise rename the newest non-live ebuild from PV Old to remote PV New, and dropping Old would leave a planned-remaining compile-pin overlay atom (`=dev-lang/bun-bin-Old`) unsatisfied, the program SHALL **not** rename Old away. It SHALL instead: (1) add `bun-bin-New.ebuild` with `SLOT="0"` (copying the template body from Old, then setting SLOT and install-layout conditionals for newest); (2) rewrite Old’s ebuild to `SLOT="${Old PV}"` so it remains the versioned-only pin; (3) run `ebuild … manifest` and package `egencache` covering both ebuilds; (4) create the signed overlay commit staging the new ebuild, the rewritten Old ebuild, `Manifest`, and md5-cache paths. When Old is not required as an exact pin, bun-bin GitMv SHALL keep renaming the newest ebuild to New as specified for other `GitMvAndManifest` packages.

#### Scenario: Pin kept while latest is added

- **WHEN** bun-bin newest is `1.3.14` with `SLOT="0"`, remote latest is `1.4.2`, and a remaining opencode ebuild contains `=dev-lang/bun-bin-1.3.14`
- **THEN** apply adds `bun-bin-1.4.2.ebuild` with `SLOT="0"`
- **AND** `bun-bin-1.3.14.ebuild` remains with `SLOT="1.3.14"`
- **AND** `1.3.14` is not renamed away

#### Scenario: Unpinned bun-bin still renames

- **WHEN** bun-bin newest is `1.4.2` and no remaining overlay ebuild contains `=dev-lang/bun-bin-1.4.2`
- **THEN** GitMv may rename `bun-bin-1.4.2.ebuild` to the remote newer PV as for other GitMv packages
