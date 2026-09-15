## MODIFIED Requirements

### Requirement: Signed assets commit and push

After writing sidecars for a package version, the program SHALL create a GPG-signed git commit in the assets worktree that stages only those new/changed sidecar paths (including sidecars for every distfile published for that PV), with commit message `category/package: version` (version without leading `v`), then `git push` to the worktree’s configured remote. Push failure SHALL be a hard failure for that package’s update attempt. The program SHALL NOT leave a successful package apply that depends on unpublished assets.

#### Scenario: Commit message matches overlay style

- **WHEN** assets commit is created for `dev-util/beads` at `1.0.5`
- **THEN** the commit message is exactly `dev-util/beads: 1.0.5`

#### Scenario: Push required

- **WHEN** the signed assets commit succeeds but `git push` fails
- **THEN** the package update hard-fails and overlay mutation for that package does not proceed

#### Scenario: Multi-distfile sidecars in one commit

- **WHEN** publishing two required distfiles for the same PV (for example a deps tarball plus a companion the package still requires)
- **THEN** one assets commit stages sidecars for both basenames under that package directory with message `category/package: version`

#### Scenario: Opencode deps-only sidecars in one commit

- **WHEN** publishing `opencode-2.0.3-deps.tar.xz` for `dev-util/opencode`
- **THEN** one assets commit stages sidecars for that basename under `dev-util/opencode/` with message `dev-util/opencode: 2.0.3`
- **AND** the commit is not required to stage a models.json sidecar

### Requirement: Multi-asset reuse requires all basenames

When materializing a PV via reuse of an existing assets release, the program SHALL treat reuse as successful only when the release tag `{pn}-{pv}` exists and **every** required asset basename for that package/PV is present and downloadable. If the tag is missing, or any required basename is missing, the program SHALL treat the outcome as not-found for reuse and take the full materialize path (or hard-fail if full path is not applicable). Partial presence of a subset of required assets SHALL NOT count as successful reuse. Extra unrequired assets on the tag (for example an unused models.json) SHALL NOT cause reuse to fail.

#### Scenario: Both deps and models present

- **WHEN** release `opencode-2.0.3` has assets `opencode-2.0.3-deps.tar.xz` and `opencode-2.0.3-models.json`
- **THEN** reuse for opencode at that PV succeeds
- **AND** the required download is the deps tarball (models.json is extra/unrequired)

#### Scenario: Deps without models is reusable

- **WHEN** release `opencode-2.0.3` has only `opencode-2.0.3-deps.tar.xz`
- **THEN** reuse for opencode at that PV succeeds (models.json is not a required basename)

#### Scenario: Opencode deps-only reuse

- **WHEN** release `opencode-2.0.3` has asset `opencode-2.0.3-deps.tar.xz`
- **THEN** reuse for opencode at that PV downloads that file
- **AND** a models.json asset is not required

#### Scenario: Extra unused models.json does not block reuse

- **WHEN** release `opencode-2.0.3` has `opencode-2.0.3-deps.tar.xz` and also `opencode-2.0.3-models.json`
- **THEN** reuse for opencode at that PV succeeds using the deps asset

### Requirement: Existing release tag blocks required full publication

When a `DepsAndAssets` PV requires full materialization/publication, the program SHALL permit that full path only when the target assets release tag does not exist at classification and route revalidation. If initial classification finds the tag because its required asset set is partial, or because a complete release cannot be reused for another forced-full reason, update SHALL hard-fail that package before materialize-image admission. If a tag or route mismatch is first observed during the pre-unit recheck, update SHALL hard-fail before that PV's local assets/overlay mutation or remote publication. The failure SHALL identify the assets owner, repository, and release tag and SHALL direct the operator to remove or repair the conflicting release externally before retrying.

The program SHALL NOT upload into, replace assets on, delete, or recreate a release tag observed before the full-publication attempt or at its route recheck. This SHALL NOT remove the existing best-effort rollback deletion of a release created by the current attempt when a later upload fails. A GitHub tag created externally after the final recheck MAY still cause release creation to fail after assets-repository work; existing partial-success diagnostics apply. `outdated` MAY continue reporting the package as needs-work but SHALL NOT describe a partial or forced-full release as reusable.

For `dev-util/opencode`, the required asset set is the deps tarball only. Presence or absence of a models.json companion on an existing tag SHALL NOT by itself classify the release as a partial required set.

#### Scenario: Partial release blocks full publication

- **WHEN** a DepsAndAssets release tag exists but lacks a still-required asset basename (not an unrequired extra such as opencode models.json)
- **THEN** initial classification hard-fails the package before image admission and identifies the conflicting release tag

#### Scenario: Opencode deps present is complete

- **WHEN** an opencode release tag contains its deps asset and may or may not contain a models.json file
- **THEN** classification does not hard-fail solely because models.json is missing or extra

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
