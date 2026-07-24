## ADDED Requirements

### Requirement: Known apply hard-fail classes are identifiable

When an apply unit hard-fails for one of the following known classes, the operator-facing message SHALL identify the class of problem and remain actionable (recovery or next step when applicable):

1. Involved paths dirty in git  
2. Package md5-cache incomplete or mismatched (with gencache / gencache --force guidance as already required by md5-cache capability)  
3. Missing `assets-path` when DepsAndAssets requires assets publish  
4. Missing GitHub token when DepsAndAssets requires release publish  
5. Invalid package key  
6. Runtime-lane planning produced zero planned package PVs  

Internal representation of these failures MAY be structured types, but the operator message SHALL NOT be an opaque empty string.

#### Scenario: Dirty paths message is identifiable

- **WHEN** a unit hard-fails because involved ebuild and/or Manifest paths are dirty
- **THEN** the hard-fail message indicates dirty involved paths (or equivalent clear wording)

#### Scenario: Missing assets-path message is identifiable

- **WHEN** a DepsAndAssets unit hard-fails because assets-path is not configured
- **THEN** the hard-fail message indicates that assets-path is required
