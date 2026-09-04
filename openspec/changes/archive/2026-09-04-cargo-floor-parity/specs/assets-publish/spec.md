## ADDED Requirements

### Requirement: Existing release tag blocks required full publication

When a `DepsAndAssets` PV requires full materialization/publication, the program SHALL permit that full path only when the target assets release tag does not exist at classification and route revalidation. If initial classification finds the tag because its required asset set is partial, or because a complete release cannot be reused for another forced-full reason, update SHALL hard-fail that package before materialize-image admission. If a tag or route mismatch is first observed during the pre-unit recheck, update SHALL hard-fail before that PV's local assets/overlay mutation or remote publication. The failure SHALL identify the assets owner, repository, and release tag and SHALL direct the operator to remove or repair the conflicting release externally before retrying.

The program SHALL NOT upload into, replace assets on, delete, or recreate a release tag observed before the full-publication attempt or at its route recheck. This SHALL NOT remove the existing best-effort rollback deletion of a release created by the current attempt when a later upload fails. A GitHub tag created externally after the final recheck MAY still cause release creation to fail after assets-repository work; existing partial-success diagnostics apply. `outdated` MAY continue reporting the package as needs-work but SHALL NOT describe a partial or forced-full release as reusable.

#### Scenario: Partial release blocks full publication

- **WHEN** an opencode release tag contains its deps asset but lacks its required models companion
- **THEN** initial classification hard-fails the package before image admission and identifies the conflicting release tag

#### Scenario: Complete release blocks forced-full publication

- **WHEN** every required release asset exists but the PV requires full materialization because no reuse-write floor can be derived
- **THEN** update hard-fails before materialization rather than mutating the existing release or pretending the unit can reuse

#### Scenario: Route race does not switch materialize class

- **WHEN** a PV was admitted as full but its release tag appears before that PV's mutation recheck
- **THEN** update hard-fails before that unit's assets/overlay mutation rather than switching to reuse or publishing into the tag

#### Scenario: Current-attempt upload rollback remains allowed

- **WHEN** the manager creates a previously absent release and a subsequent asset upload fails
- **THEN** it may best-effort delete that newly created release as already required, despite not deleting pre-existing releases

#### Scenario: Missing release permits full publication

- **WHEN** a PV requires full materialization and its target release tag does not exist
- **THEN** the normal full materialize and new-release publication path remains eligible
