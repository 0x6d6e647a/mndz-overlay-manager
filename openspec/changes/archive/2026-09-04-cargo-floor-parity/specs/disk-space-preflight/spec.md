## MODIFIED Requirements

### Requirement: Reuse versus full classification for gate estimates

Before computing disk-space unit needs for a `DepsAndAssets` package that needs work and may publish or fetch assets, `update` SHALL classify each planned heavy PV unit as **reuse**, **full path**, or package hard-failure using a GitHub release asset probe after assets token and assets-path requirements for that run have been satisfied when any such package needs work. The classification SHALL use every required primary and companion basename and the plan's forced-full status.

Classification SHALL follow:

1. Complete required release asset set present and PV not forced full -> **reuse**. Its baseline SHALL sum one size per required basename: positive GitHub asset size when available, otherwise the exact matching Manifest `DIST` size, otherwise the reuse ecosystem floor for that unresolved basename. Apply reuse expansion and the fixed safety margin to that complete-set baseline.
2. No release tag -> **full path**; baseline from Manifest or ecosystem full-path floor and full-path expansion factors.
3. Existing partial release, or existing complete release for a forced-full PV -> **hard-fail that package** because full publication cannot mutate an existing tag; exclude it from gate units.
4. Transport, HTTP API, or parse failure for the probe -> **hard-fail that package** (not the whole command solely for that package); exclude it from gate units.
5. Unusable or missing token when assets work requires a token at hard-require time -> **spine hard-fail** before classification of assets units.

Absence of a release tag SHALL NOT be a package hard-fail; it SHALL select the full-path class. Presence of only a subset of required assets SHALL NOT be treated as release absence or reuse.

#### Scenario: Existing asset uses reuse estimate

- **WHEN** a needs-work unit is not forced full and every required release asset is present with usable sizes
- **THEN** the unit's temp need is derived from the sum of every required asset size as a reuse estimate, not a full-path ecosystem expansion

#### Scenario: Missing asset uses full path estimate

- **WHEN** a needs-work unit has no target release tag or matching asset because the release is absent
- **THEN** the unit is estimated as full-path materialize for free-space feasibility

#### Scenario: Missing companion size uses exact Manifest fallback

- **WHEN** a reusable multi-asset release has a positive primary API size but no usable companion API size and Manifest has an exact positive companion `DIST` size
- **THEN** the reuse baseline includes both the primary API size and the companion Manifest size

#### Scenario: Forced-full complete release hard-fails package

- **WHEN** every required asset exists but the planned PV is forced full
- **THEN** classification hard-fails that package and excludes it from disk-gate units rather than using a reuse estimate

#### Scenario: Partial release hard-fails package

- **WHEN** the target release exists with only a subset of required primary and companion assets
- **THEN** classification hard-fails that package and excludes it from disk-gate units rather than estimating a full path that cannot publish

#### Scenario: Probe error hard-fails package not whole inventory gate math

- **WHEN** the release probe fails with a network or API error for one needs-work package and other packages classify successfully
- **THEN** the failing package is hard-failed and excluded from unit needs while the gate still evaluates the successful packages' units
