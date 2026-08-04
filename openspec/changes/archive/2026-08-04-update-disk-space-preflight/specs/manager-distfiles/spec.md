## ADDED Requirements

### Requirement: Manager distfiles free space is a hard feasibility surface for update

The effective manager distfiles path SHALL be included as a hard free-space surface in the `disk-space-preflight` feasibility gate for `update`. Planned `ebuild … manifest` fetches that would place missing distfiles into that path SHALL contribute to estimated need on that filesystem. Distfiles already present under the effective path SHALL NOT require additional free-space reservation for the gate.

#### Scenario: Large missing bin distfiles fail gate when free is low

- **WHEN** `update` will run `ebuild … manifest` for a package whose Manifest (or planned SRC_URI set) implies fetching large missing distfiles into manager distfiles and free space on that path is below the concurrent sum of such needs under `--jobs`
- **THEN** the disk-space feasibility gate hard-fails before package mutation with a message that names the manager distfiles path

#### Scenario: Present distfiles do not inflate need

- **WHEN** all distfiles required for the planned units already exist under the effective manager distfiles path
- **THEN** manager distfiles need for those files is zero for the gate even if the files are large
