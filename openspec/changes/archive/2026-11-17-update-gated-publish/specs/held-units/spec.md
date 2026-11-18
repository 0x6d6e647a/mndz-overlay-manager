# Spec Delta

## Purpose

Save an `update` unit's uncommitted work for later inspection, and a future `resume`, before rolling the overlay back, so a failed or stopped unit leaves the worktree clean without losing anything.

## ADDED Requirements

### Requirement: Units are held instead of left dirty

A unit SHALL be held when it has changed overlay files and has not committed, and one of these happens: its gate fails, the verification of its published assets fails, the command is interrupted, publishing halted, or it is in a dependency cycle. Holding means saving its work, then rolling its overlay changes back.

#### Scenario: Gate failure

- **WHEN** the gate for `dev-util/hk-2.13.0` fails
- **THEN** a held entry for that unit exists
- **AND** `dev-util/hk` in the overlay worktree matches `HEAD`

#### Scenario: Failure before the gate is not held

- **WHEN** `ebuild … manifest` fails for a unit after its rename
- **THEN** no held entry is written and the half-applied warning specified by `update-apply` is logged

### Requirement: Held entry location

A held entry SHALL be written at `<cache>/mndz/overlay-manager/held/<run-id>/<category>/<pn>-<pv>/`. `<cache>` is `XDG_CACHE_HOME` when set and non-empty, otherwise `$HOME/.cache`. `<run-id>` is the `update` run id.

#### Scenario: Default cache home

- **WHEN** `XDG_CACHE_HOME` is unset, `HOME` is `/home/op`, and unit `dev-util/hk-2.13.0` is held in run `20261117T101500-0800-4242.a8f3`
- **THEN** its entry is `/home/op/.cache/mndz/overlay-manager/held/20261117T101500-0800-4242.a8f3/dev-util/hk-2.13.0/`

### Requirement: Held entry contents

A held entry SHALL contain:

- a patch of the unit's overlay changes against `HEAD`, applicable with `git apply`, including renames, deletions, binary changes, and md5-cache entries;
- every distfile the unit built for publishing;
- copies of its gated runs' logs, when any ran;
- a metadata file.

#### Scenario: Patch restores the unit

- **WHEN** the held patch is applied with `git apply` to the same `HEAD`
- **THEN** the package directory and its md5-cache entries match what the unit had before rollback

#### Scenario: Built tarball is kept

- **WHEN** a full-path unit is held after its gate failed
- **THEN** its built distfile is in the entry and has the hashes recorded in the patched Manifest

### Requirement: Held entry metadata

The metadata file SHALL be JSON with a schema version. It SHALL record:

- the package, PV, technique, and path (full or reuse);
- the lanes gated and each run's outcome;
- why it was held (`gate`, `verify`, `interrupted`, `halted`, or `cycle`);
- the base `HEAD` commit;
- the planned release identity, and whether each asset was published;
- the run id and time.

#### Scenario: Verify failure after publish

- **WHEN** a unit is held because its published asset failed verification
- **THEN** the metadata records reason `verify` and that the asset was published

#### Scenario: Gate failure before publish

- **WHEN** a unit is held because its gate failed
- **THEN** the metadata records reason `gate`, each run's `fail: <stage>` or skip outcome, and that nothing was published

### Requirement: Rollback only after a complete capture

The program SHALL roll a unit back only after its held entry is completely written. If writing the entry fails, the program SHALL leave the unit's overlay changes in place. It SHALL log an error naming the unit's changed paths and why the capture failed.

#### Scenario: Cache disk full

- **WHEN** writing the held entry fails because the cache filesystem is full
- **THEN** the unit's renamed ebuild and Manifest remain in the worktree
- **AND** the error says the work was not rolled back and names the paths

### Requirement: Rollback touches only the unit's paths

Rollback SHALL restore exactly the paths the unit changed to their `HEAD` state, in the worktree and the index, and SHALL remove files the unit created. Other paths SHALL NOT be changed.

#### Scenario: Renamed ebuild restored

- **WHEN** a held unit had renamed `hk-2.12.0.ebuild` to `hk-2.13.0.ebuild`
- **THEN** after rollback `hk-2.12.0.ebuild` exists as at `HEAD` and `hk-2.13.0.ebuild` does not

#### Scenario: Other packages untouched

- **WHEN** a unit is rolled back while another package has uncommitted work in progress
- **THEN** the other package's files are unchanged

### Requirement: Interrupted units are held

When `update` receives an interrupt or termination signal, each unit with uncommitted overlay changes SHALL be held with reason `interrupted` before the program exits. A unit whose overlay commit already exists SHALL NOT be held.

#### Scenario: Ctrl-C during a gated run

- **WHEN** the operator presses Ctrl-C while `dev-util/hk-2.13.0` is being gated
- **THEN** its smoke container is removed, it is held with reason `interrupted`, and `dev-util/hk` matches `HEAD`

### Requirement: Held entries are reported

For each held unit, the error SHALL name the held entry's path and the reason it was held.

#### Scenario: Error names the entry

- **WHEN** unit `dev-util/hk-2.13.0` is held
- **THEN** the logged error contains the path of its held entry

### Requirement: Held entries are kept

The program SHALL NOT delete or prune held entries. `eclean` SHALL NOT remove them.

#### Scenario: eclean leaves held entries

- **WHEN** the operator runs `eclean`
- **THEN** every directory under `held/` is unchanged

#### Scenario: Retry keeps the earlier entry

- **WHEN** a unit held in one run is held again in a later run
- **THEN** both runs' entries exist
