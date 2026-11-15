# Spec Delta

## MODIFIED Requirements

### Requirement: Ebuild manifest uses manager DISTDIR and empty GENTOO_MIRRORS

Every Portage `ebuild … manifest` invocation performed by the program SHALL run in the Portage tools container with an environment that includes `DISTDIR` set to the effective manager distfiles path (bound at the same absolute path) and `GENTOO_MIRRORS` set to the empty string, merged onto the container's environment so that its other variables (including `PATH`) remain available. The program SHALL NOT rely on `FEATURES=-mirror` as the mechanism to disable Gentoo mirror URL construction.

#### Scenario: Manifest child sees private DISTDIR

- **WHEN** the program runs `ebuild … manifest` for a package update
- **THEN** that process environment sets `DISTDIR` to the effective manager distfiles path

#### Scenario: Manifest child disables Gentoo mirrors list

- **WHEN** the program runs `ebuild … manifest` for a package update
- **THEN** that process environment sets `GENTOO_MIRRORS` to the empty string
