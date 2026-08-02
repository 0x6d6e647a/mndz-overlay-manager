## MODIFIED Requirements

### Requirement: DepsAndAssets multi-lane apply

For packages with technique `DepsAndAssets`, apply SHALL use the runtime-lane planner for the package’s ecosystem to obtain the planned set of PVs and KEYWORDS, materialize each PV that needs work (full or reuse path), commit each successful unit before the next, and perform exact-set prune of non-live ebuilds after all planned PVs succeed. Multi-PV ordering and failure isolation SHALL match multi-unit behavior (later unit failure does not roll back earlier committed units).

When more than one planned PV needs work in the same package apply, the program SHALL order those units so that **missing** planned PVs (no local non-live ebuild at that PV) are materialized **before** pure **content-fix** units (a local non-live ebuild at that PV exists but ebuild content, KEYWORDS, runtime field, and/or Manifest dist entry is inadequate). Within each of those two groups, ordering SHALL be stable by PV comparison (numeric components ascending). A PV that is missing SHALL be classified as missing for this order even if content-fix checks would also apply. This order SHALL keep discovery-time donor ebuild paths usable for new-PV template reads that fall back to an existing local ebuild, so a content-fix revision bump does not delete that donor path before missing PVs run.

#### Scenario: Multiple planned PVs

- **WHEN** the plan contains two distinct PVs that both need materialization and both succeed
- **THEN** the first PV’s overlay commit exists in HEAD before the second PV’s mutation begins

#### Scenario: Missing PV before content-fix revision bump

- **WHEN** a package has a local ebuild at PV `0.82.0` that needs a content-fix revision bump and the plan also requires a missing newer PV `0.88.0`
- **THEN** apply materializes `0.88.0` (including its overlay mutation using an existing local ebuild as template when needed) before the content-fix unit rewrites and replaces the `0.82.0` revision path
- **AND** the content-fix unit’s signed overlay commit does not run before the missing PV unit has completed its template read for overlay rewrite

#### Scenario: Only content-fix units keep PV order

- **WHEN** every planned PV that needs work already has a local non-live ebuild (content-fix only; no missing PVs)
- **THEN** units run in stable ascending PV order among those content-fix units

### Requirement: Known apply hard-fail classes are identifiable

When an apply unit hard-fails for one of the following known classes, the operator-facing message SHALL identify the class of problem and remain actionable (recovery or next step when applicable):

1. Involved paths dirty in git  
2. Package md5-cache incomplete or mismatched (with gencache / gencache --force guidance as already required by md5-cache capability)  
3. Missing `assets-path` when DepsAndAssets requires assets publish  
4. Missing GitHub token when DepsAndAssets requires release publish  
5. Invalid package key  
6. Runtime-lane planning produced zero planned package PVs  
7. Missing donor or template ebuild path when a DepsAndAssets unit must read an existing ebuild to rewrite or create a planned PV  

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
