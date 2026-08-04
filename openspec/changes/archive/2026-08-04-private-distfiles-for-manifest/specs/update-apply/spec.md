## ADDED Requirements

### Requirement: Ebuild manifest runs under manager distfiles environment

When apply runs Portage `ebuild` with the `manifest` command, that invocation SHALL use the effective manager distfiles environment required by `manager-distfiles` (`DISTDIR` set to the effective path; `GENTOO_MIRRORS` empty), not an unset environment that silently inherits a host sticky system DISTDIR by default.

#### Scenario: GitMv manifest uses manager DISTDIR

- **WHEN** a `GitMvAndManifest` unit runs `ebuild … manifest`
- **THEN** the ebuild process receives `DISTDIR` set to the effective manager distfiles path

#### Scenario: DepsAndAssets manifest uses manager DISTDIR

- **WHEN** a `DepsAndAssets` unit runs `ebuild … manifest`
- **THEN** the ebuild process receives `DISTDIR` set to the effective manager distfiles path

## MODIFIED Requirements

### Requirement: Known apply hard-fail classes are identifiable

When an apply unit hard-fails for one of the following known classes, the operator-facing message SHALL identify the class of problem and remain actionable (recovery or next step when applicable):

1. Involved paths dirty in git  
2. Package md5-cache incomplete or mismatched (with gencache / gencache --force guidance as already required by md5-cache capability)  
3. Missing `assets-path` when DepsAndAssets requires assets publish  
4. Missing GitHub token when DepsAndAssets requires release publish  
5. Invalid package key  
6. Runtime-lane planning produced zero planned package PVs  
7. Missing donor or template ebuild path when a DepsAndAssets unit must read an existing ebuild to rewrite or create a planned PV  
8. `ebuild … manifest` failure attributable to sticky DISTDIR or distfiles ownership (operation not permitted on rename under distfiles), with guidance toward a user-owned manager distfiles path as specified by `manager-distfiles`

When the selected template or donor ebuild path does not exist on disk at read time, the unit SHALL hard-fail with a message that identifies the missing template/donor (including package and path or planned PV when known) and SHALL NOT abort the process with an uncaught filesystem exception. Internal representation of these failures MAY be structured types, but the operator message SHALL NOT be an opaque empty string.

#### Scenario: Dirty paths message is identifiable

- **WHEN** a unit hard-fails because involved ebuild and/or Manifest paths are dirty
- **THEN** the hard-fail message indicates dirty involved paths (or equivalent clear wording)

#### Scenario: Missing assets-path message is identifiable

- **WHEN** a DepsAndAssets unit hard-fails because assets-path is not configured
- **THEN** the hard-fail message indicates that assets-path is required

#### Scenario: Missing donor template is hard-fail not crash

- **WHEN** a DepsAndAssets unit would read a template or donor ebuild path that does not exist
- **THEN** that unit hard-fails with a message identifying missing donor or template
- **AND** the process does not terminate solely via an uncaught openFile / does-not-exist IOException for that path

#### Scenario: Sticky distfiles manifest failure is identifiable

- **WHEN** a unit hard-fails because `ebuild … manifest` failed with an operation-not-permitted rename under distfiles
- **THEN** the hard-fail message indicates a sticky or ownership distfiles problem and points at configuring a private manager distfiles path
