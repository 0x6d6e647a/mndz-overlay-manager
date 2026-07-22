## MODIFIED Requirements

### Requirement: Overlay apply after assets publish

After successful assets publish for a Go package, the program SHALL: ensure the ebuild’s assets `SRC_URI` uses `${PV}` parameterization while preserving the full mndz-overlay-assets download path (see assets SRC_URI requirement); place the ebuild at the target version filename (new PV, or same PV with increased `-rN` when only content/revision bump is required); run `ebuild … manifest` from the package directory so Portage fetches distfiles including the new vendor URL; verify integrity; then include overlay paths in the phase-2 signed commit set using message `category/package: version` (version string without leading `v`, including `-rN` when the filename carries a revision).

When a planned PV is already present as one or more local non-live ebuilds and the apply is a same-PV content or Manifest fix (not a new PV), the program SHALL choose the write revision by taking the **highest local revision** for that PV (unrevised/bare is lower than `-r1`, which is lower than `-r2`, and so on) and writing the next revision (`nextRevisionVersion`): bare only → `-r1`, highest local `-rN` → `-rN+1`. The program SHALL NOT always write `-r1` from a bare planned PV when a higher local revision already exists. Asset and release identity SHALL continue to use PV without revision.

#### Scenario: Version bump filename

- **WHEN** local newest is `crush-0.76.0.ebuild` and remote PV is `0.77.0`
- **THEN** the overlay ebuild path becomes `crush-0.77.0.ebuild` with assets SRC_URI using `${PV}`

#### Scenario: Same PV SRC_URI fix bumps revision

- **WHEN** local newest is `dolt-2.1.6.ebuild` with a frozen non-`${PV}` assets URL and remote PV is still `2.1.6`
- **THEN** the program produces `dolt-2.1.6-r1.ebuild` with parameterized assets SRC_URI

#### Scenario: Same PV fix advances past existing revision

- **WHEN** local has `dolt-2.1.6-r1.ebuild` (and planned remote PV is still `2.1.6`) and a content or Manifest fix is required
- **THEN** the program produces `dolt-2.1.6-r2.ebuild` (not an overwrite-only write of `-r1` as if bare were the base)
