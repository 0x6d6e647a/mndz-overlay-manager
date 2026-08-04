## ADDED Requirements

### Requirement: Hardcoded policy for dev-util/autolith

The hardcoded package policy map SHALL include `dev-util/autolith` with update source GitHub owner `luciusmagn`, repository `autolith`, tag prefix `v`, and technique `DepsAndAssets` with ecosystem `Sbcl`.

#### Scenario: Policy lookup

- **WHEN** the library resolves policy for package key `dev-util/autolith`
- **THEN** the technique is `DepsAndAssets Sbcl` and the source is GitHub `luciusmagn/autolith` with tag prefix `v`

### Requirement: Preserve Autolith template body on Sbcl apply

When rewriting a `DepsAndAssets Sbcl` ebuild for assets parameterization, SBCL atom alignment, KEYWORDS, or PV filename update, the program SHALL preserve template-owned body that is not those rewritten fields. This includes private-prefix install logic, wrapper generation, identity stamping, network-install disablement, core build steps, `IUSE`/`RESTRICT` test gating, and any non-assets `SRC_URI` companions or `FILESDIR`/`PATCHES` references present on the donor ebuild. The program SHALL NOT strip those constructs when parameterizing deps assets URLs to `${PV}`.

#### Scenario: Template survives PV bump

- **WHEN** apply updates autolith from `0.17.2` to `0.18.0` using the seed ebuild as donor
- **THEN** the new ebuild still contains the seed’s private layout / stamp / network-disable / test USE structure
- **AND** the deps assets URL uses `${PV}` for `0.18.0`
